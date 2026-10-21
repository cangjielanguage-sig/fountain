/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fmq.server

import std.collection.ArrayList
import std.fs.*
import std.net.{TcpSocket, IPSocketAddress}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataAny
import fountain::f_mq.base.{MQErrorCode, MQProtocol}
import fountain::f_mq.base.payload.MQResult
import fountain::f_net.SocketBuffer
import fountain::f_net.server.Server
import fountain::f_protocol.default.Message
import fountain::fmq.manager.{MQManager, MQManagerArgs}
import fountain::fmq.test.TestDirs

/**
 * 管理端六个子命令的独立用例。
 *
 * 放在 `fmq.server` 包内是为了复用 `MQServerOptions` / `MQServer` 的测试装配
 * （两者对包外不可见）；`MQManager` 本身是 public，调用方式与真实 CLI 一致。
 */
@Test
class MQManagerTest {
    private static let nextPort = AtomicInt64(28100)

    private static func freePort(): UInt16 {
        var attempt = 0
        while (attempt < 200) {
            let port = UInt16(nextPort.fetchAdd(1) % 60000)
            try {
                let probe = TcpSocket(IPSocketAddress("127.0.0.1", port))
                probe.close()
                return port
            } catch (_: Exception) {
                attempt++
            }
        }
        throw Exception("cannot find a free port")
    }

    private static func waitReady(port: UInt16): Unit {
        var ready = false
        var tries = 0
        while (!ready && tries < 300) {
            try {
                let probe = TcpSocket(IPSocketAddress("127.0.0.1", port))
                probe.close()
                ready = true
            } catch (_: Exception) {
                sleep(Duration.millisecond * 10)
                tries++
            }
        }
        if (!ready) {
            throw Exception("server on ${port} did not start")
        }
    }

    private static func startServer(name: String): (MQServer, String) {
        let root = TestDirs.of("manager", name)
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let port = freePort()
        let nodes = ["127.0.0.1:${port}"]
        let options = MQServerOptions(port, nodes, 0, Duration.second * 10, 3, Duration.hour * 72,
            "${root}/logs", "${root}/dead", 1024 * 1024, Duration.hour * 72, 0, "${root}/metas")
        let server = MQServer(options)
        server.start()
        waitReady(port)
        (server, "127.0.0.1:${port}")
    }

    private static func manager(server: String, args: Array<String>): MQManager {
        let all = ArrayList<String>()
        for (arg in args) {
            all.add(arg)
        }
        all.add("--server=${server}")
        MQManager(MQManagerArgs.parse(all.toArray()).getOrThrow())
    }

    /** 非法组名在管理端本地被拒：非 0 退出码，且不发请求（A05）。 */
    /** 服务端回 ERROR 时必须打印服务端错误，而不是「无法连接」（A65）。 */
    @TestCase
    public func serverErrorIsNotReportedAsConnectionFailure(): Unit {
        let port = freePort()
        let server = Server<DataAny>(bindAt: port, checkDuration: Duration.second * 30, executors: 2,
            checker: {=> Message.ping()})
        spawn {
            server.start({_, request =>
                Some(MQProtocol.fail(request, MQErrorCode.INTERNAL, "boom from server"))
            })
        }
        try {
            waitReady(port)
            let manager = MQManager(MQManagerArgs.parse(
                ["listTopics", "--server=127.0.0.1:${port}"]).getOrThrow())
            @Assert(manager.run() == 1)
        } finally {
            server.close()
        }
    }

    /** 返回 RESP 但不是快照：按协议错误处理，同样不能报成连接失败（A65）。 */
    @TestCase
    public func nonSnapshotResponseIsProtocolError(): Unit {
        let port = freePort()
        let server = Server<DataAny>(bindAt: port, checkDuration: Duration.second * 30, executors: 2,
            checker: {=> Message.ping()})
        spawn {
            server.start({_, request =>
                Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            })
        }
        try {
            waitReady(port)
            let manager = MQManager(MQManagerArgs.parse(
                ["listTopics", "--server=127.0.0.1:${port}"]).getOrThrow())
            @Assert(manager.run() == 1)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func invalidGroupIsRejectedLocally(): Unit {
        let (server, address) = startServer("bad_group")
        try {
            @Assert(manager(address, ["registerTopic", "/t", "1"]).run() == 0)
            // 指向不存在的地址也应当先被本地校验挡下（否则会打印「无法连接」）
            let offline = MQManager(MQManagerArgs.parse(
                ["registerSubscriber", "/t", "g 1", "--server=127.0.0.1:1"]).getOrThrow())
            @Assert(offline.run() == 1)
            @Assert(manager(address, ["deleteSubscribeGroup", "/t", "g/1"]).run() == 1)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func sixSubcommandsSucceedAndMutateState(): Unit {
        let (server, address) = startServer("flow")
        try {
            @Assert(manager(address, ["registerTopic", "/t", "2"]).run() == 0)
            @Assert(manager(address, ["listTopics"]).run() == 0)
            @Assert(manager(address, ["registerSubscriber", "/t", "g"]).run() == 0)
            @Assert(manager(address, ["listSubscribeGroups", "/t"]).run() == 0)

            // 重复注册：主题与订阅组都返回 1
            @Assert(manager(address, ["registerTopic", "/t", "2"]).run() == 1)
            @Assert(manager(address, ["registerSubscriber", "/t", "g"]).run() == 1)

            @Assert(manager(address, ["deleteSubscribeGroup", "/t", "g"]).run() == 0)
            @Assert(manager(address, ["deleteSubscribeGroup", "/t", "g"]).run() == 1)
            @Assert(manager(address, ["deleteTopic", "/t"]).run() == 0)
            @Assert(manager(address, ["deleteTopic", "/t"]).run() == 1)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func subscriberRequiresExistingTopic(): Unit {
        let (server, address) = startServer("missing-topic")
        try {
            @Assert(manager(address, ["registerSubscriber", "/missing", "g"]).run() == 1)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func emptyListsReturnZero(): Unit {
        let (server, address) = startServer("empty")
        try {
            @Assert(manager(address, ["listTopics"]).run() == 0)
            @Assert(manager(address, ["listSubscribeGroups", "/none"]).run() == 0)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func invalidQueueNumFailsBeforeSending(): Unit {
        let (server, address) = startServer("bad-queue-num")
        try {
            // 非整数：本地解析失败，返回 2
            @Assert(manager(address, ["registerTopic", "/t", "abc"]).run() == 2)
            // 0 队列：服务端拒绝，返回 1
            @Assert(manager(address, ["registerTopic", "/t", "0"]).run() == 1)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func connectionFailureReturnsOne(): Unit {
        // 探测出一个空闲端口但不启动服务端
        let port = freePort()
        let manager = MQManager(MQManagerArgs.parse(
            ["listTopics", "--server=127.0.0.1:${port}"]).getOrThrow())
        @Assert(manager.run() == 1)
    }
    @TestCase
    public func registerTopicWithDelayingAndStats(): Unit {
        let (server, address) = startServer("delaying")
        try {
            @Assert(manager(address, ["registerTopic", "/d", "2", "delaying=1m1s"]).run() == 0)
            @Assert(manager(address, ["listTopics"]).run() == 0)
            @Assert(manager(address, ["stats"]).run() == 0)
            @Assert(manager(address, ["stats", "/d"]).run() == 0)
            @Assert(manager(address, ["stats", "/missing"]).run() == 0)
        } finally {
            server.close()
        }
    }

    @TestCase
    public func invalidDelayingReturnsTwo(): Unit {
        let (server, address) = startServer("bad-delaying")
        try {
            @Assert(manager(address, ["registerTopic", "/d", "2", "delaying=abc"]).run() == 2)
            @Assert(manager(address, ["registerTopic", "/d", "2", "delaying=-1s"]).run() == 2)
            @Assert(manager(address, ["registerTopic", "/d", "2", "not-delaying=1s"]).run() == 2)
        } finally {
            server.close()
        }
    }
    @TestCase
    public func statsConnectionFailureReturnsOne(): Unit {
        let port = freePort()
        @Assert(manager("127.0.0.1:${port}", ["stats"]).run() == 1)
    }

    /** 配置参数可出现在子命令前后：解析器跳过它们定位子命令（A69）。 */
    @TestCase
    public func configTokensAroundSubcommandAreSkipped(): Unit {
        let before = MQManagerArgs.parse(["--mqServer_port=2400", "listTopics"]).getOrThrow()
        @Assert(before.command == "listTopics")
        @Assert(before.operands.size == 0)

        let after = MQManagerArgs.parse(["listTopics", "--mqServer_port=2400"]).getOrThrow()
        @Assert(after.command == "listTopics")
        @Assert(after.operands.size == 0)

        let mixed = MQManagerArgs.parse(["registerTopic", "/t", "2", "--mqServer_port=2400"]).getOrThrow()
        @Assert(mixed.command == "registerTopic")
        @Assert(mixed.operands.size == 2)

        // 单横线形式的值是下一个 token，也要一起跳过
        let short = MQManagerArgs.parse(["-mqServer_port", "2400", "listTopics"]).getOrThrow()
        @Assert(short.command == "listTopics")
        @Assert(short.operands.size == 0)
    }
}