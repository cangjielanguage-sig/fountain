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

import std.fs.*
import std.net.{TcpSocket, IPSocketAddress}
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.client.MQClient
import fountain::fmq.manager.{MQManager, MQManagerArgs}
import fountain::fmq.test.TestDirs

class ServerPortAllocator {
    private static let next = AtomicInt64(27000)

    static func freePort(): UInt16 {
        var attempt = 0
        while (attempt < 200) {
            let port = UInt16(next.fetchAdd(1) % 60000)
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
}

@Test
class MQServerTest {
    private static func options(root: String, port: UInt16, nodes: Array<String>,
        selfIndex!: Int64 = 0): MQServerOptions {
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        MQServerOptions(port, nodes, selfIndex, Duration.second * 10, 3, Duration.hour * 72,
            "${root}/logs", "${root}/dead", 1024 * 1024, Duration.hour * 72, 0, "${root}/metas")
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

    private static func register(server: String, topic: String, queueNum: Int64): Int64 {
        let args = MQManagerArgs.parse(["registerTopic", topic, "${queueNum}", "--server=${server}"]).getOrThrow()
        MQManager(args).registerTopic(topic, queueNum)
    }

    private static func registerGroup(server: String, topic: String, group: String): Int64 {
        let args = MQManagerArgs.parse(["registerSubscriber", topic, group, "--server=${server}"]).getOrThrow()
        MQManager(args).registerSubscriber(topic, group)
    }

    @TestCase
    public func bindAcceptPublishSubscribeAck(): Unit {
        let root = TestDirs.of("server", "flow")
        let port = ServerPortAllocator.freePort()
        let options = options(root, port, ["127.0.0.1:${port}"])
        let server = MQServer(options)
        try {
            @Assert(server.port == port)
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 2) == 0)
            @Assert(registerGroup(address, "/t", "g") == 0)

            let client = MQClient([address])
            try {
                client.publish("/t", "one")
                client.publish("/t", "two")
                let sid = client.subscribe("/t", subscribeGroup: "g")
                let first = client.consume(sid)
                @Assert(first.get<String>() == Some("one"))
                client.ack(sid, first.queueIndex, first.segmentedIndex, first.segmentedOffset)
                let second = client.consume(sid)
                @Assert(second.get<String>() == Some("two"))
                client.ack(sid, second.queueIndex, second.segmentedIndex, second.segmentedOffset)

                // 消费期间的新消息同样可取
                client.publish("/t", "three")
                let third = client.consume(sid)
                @Assert(third.get<String>() == Some("three"))
                client.ack(sid, third.queueIndex, third.segmentedIndex, third.segmentedOffset)
            } finally {
                client.close()
            }
        } finally {
            server.close()
        }
        // 端口可再次绑定
        let restarted = MQServer(options)
        try {
            restarted.start()
            waitReady(port)
        } finally {
            restarted.close()
        }
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    @TestCase
    public func onlyLocalQueuesAreOpened(): Unit {
        let root = TestDirs.of("server", "local")
        let port = ServerPortAllocator.freePort()
        // 两节点、本机 0；2 队列 ⇒ owners [0,1]
        let options = options(root, port, ["127.0.0.1:${port}", "127.0.0.1:1"])
        let server = MQServer(options)
        try {
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 2) == 0)
            @Assert(exists("${root}/logs/%2Ft/0"))
            @Assert(!exists("${root}/logs/%2Ft/1"))
        } finally {
            server.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    @TestCase
    public func restartRedeliversOnlyUnacked(): Unit {
        let root = TestDirs.of("server", "restart")
        let port = ServerPortAllocator.freePort()
        let options = options(root, port, ["127.0.0.1:${port}"])
        let address = "127.0.0.1:${port}"
        let firstServer = MQServer(options)
        try {
            firstServer.start()
            waitReady(port)
            @Assert(register(address, "/t", 1) == 0)
            @Assert(registerGroup(address, "/t", "g") == 0)
            let client = MQClient([address])
            try {
                client.publish("/t", "one")
                client.publish("/t", "two")
                client.publish("/t", "three")
                let sid = client.subscribe("/t", subscribeGroup: "g")
                let one = client.consume(sid)
                client.ack(sid, one.queueIndex, one.segmentedIndex, one.segmentedOffset)
                let two = client.consume(sid)
                client.ack(sid, two.queueIndex, two.segmentedIndex, two.segmentedOffset)
                // 第三条不确认
                let three = client.consume(sid)
                @Assert(three.get<String>() == Some("three"))
            } finally {
                client.close()
            }
        } finally {
            firstServer.close()
        }

        let secondServer = MQServer(options)
        try {
            secondServer.start()
            waitReady(port)
            let client = MQClient([address])
            try {
                let sid = client.subscribe("/t", subscribeGroup: "g")
                let redelivered = client.consume(sid)
                // 前两条不再出现，第三条被重投
                @Assert(redelivered.get<String>() == Some("three"))
                client.ack(sid, redelivered.queueIndex, redelivered.segmentedIndex, redelivered.segmentedOffset)
            } finally {
                client.close()
            }
        } finally {
            secondServer.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    @TestCase
    public func managerCommandsAgainstRunningServer(): Unit {
        let root = TestDirs.of("server", "manager")
        let port = ServerPortAllocator.freePort()
        let options = options(root, port, ["127.0.0.1:${port}"])
        let server = MQServer(options)
        try {
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 2) == 0)
            @Assert(registerGroup(address, "/t", "g1") == 0)

            let listTopics = MQManager(MQManagerArgs.parse(["listTopics", "--server=${address}"]).getOrThrow())
            @Assert(listTopics.listTopics() == 0)

            let listGroups = MQManager(MQManagerArgs.parse(
                ["listSubscribeGroups", "/t", "--server=${address}"]).getOrThrow())
            @Assert(listGroups.listSubscribeGroups("/t") == 0)

            // 重复注册失败
            @Assert(register(address, "/t", 2) != 0)

            // 删组后不可再用该组订阅
            @Assert(registerGroup(address, "/t", "g2") == 0)
            let deleteGroup = MQManager(MQManagerArgs.parse(
                ["deleteSubscribeGroup", "/t", "g2", "--server=${address}"]).getOrThrow())
            @Assert(deleteGroup.deleteSubscribeGroup("/t", "g2") == 0)
            let clientForGroup = MQClient([address])
            try {
                var failed = false
                try {
                    clientForGroup.subscribe("/t", subscribeGroup: "g2")
                } catch (_: Exception) {
                    failed = true
                }
                @Assert(failed)
            } finally {
                clientForGroup.close()
            }

            let deleteTopic = MQManager(MQManagerArgs.parse(["deleteTopic", "/t", "--server=${address}"]).getOrThrow())
            @Assert(deleteTopic.deleteTopic("/t") == 0)
            let client = MQClient([address])
            try {
                var threw = false
                try {
                    client.publish("/t", "after-delete")
                } catch (_: Exception) {
                    threw = true
                }
                @Assert(threw)
            } finally {
                client.close()
            }
        } finally {
            server.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    @TestCase
    public func managerConnectionFailureReturnsOne(): Unit {
        let args = MQManagerArgs.parse(["listTopics", "--server=127.0.0.1:1"]).getOrThrow()
        @Assert(MQManager(args).run() == 1)
    }

    // ===== 退出钩子与关闭容错（A58/A59） =====

    @TestCase
    public func closeIsolatesFailingStep(): Unit {
        let root = TestDirs.of("server", "close_isolate")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        let laterRan = Array<Int64>(1, repeat: 0)
        server.setCloseStepsOverride({=>
            [
                ("boom", {=> throw IllegalArgumentException("simulated close failure")}),
                ("later", {=> laterRan[0] = laterRan[0] + 1})
            ]
        })
        // 单步失败不影响后续步骤
        server.close()
        @Assert(laterRan[0] == 1)
        // 未完成：再次 close 会重试失败步骤，已成功的步骤不重复执行
        server.close()
        @Assert(laterRan[0] == 1)
        @Assert(server.isClosed())
    }

    @TestCase
    public func closeRetriesOnlyFailedStepsUntilComplete(): Unit {
        let root = TestDirs.of("server", "close_retry")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        let attempts = Array<Int64>(1, repeat: 0)
        let laterRan = Array<Int64>(1, repeat: 0)
        server.setCloseStepsOverride({=>
            [
                ("flaky", {=>
                    attempts[0] = attempts[0] + 1
                    if (attempts[0] == 1) {
                        throw IllegalArgumentException("first attempt fails")
                    }
                }),
                ("later", {=> laterRan[0] = laterRan[0] + 1})
            ]
        })
        server.close()
        @Assert(attempts[0] == 1)
        server.close()
        @Assert(attempts[0] == 2)
        @Assert(laterRan[0] == 1)
        // 完成后不再执行任何步骤
        server.close()
        @Assert(attempts[0] == 2)
    }

    @TestCase
    public func closeMakesRunReturnZero(): Unit {
        let root = TestDirs.of("server", "close_run")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        server.start()
        waitReady(port)
        server.close()
        let started = DateTime.now()
        let code = server.run()
        @Assert(code == 0)
        @Assert((DateTime.now() - started).toMilliseconds() < 1000)
    }

    @TestCase
    public func installExitHooksClosesServer(): Unit {
        let root = TestDirs.of("server", "exit_hooks")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        let captured = Array<() -> Unit>(1, repeat: {=> ()})
        let capturedSet = Array<Bool>(1, repeat: false)
        installExitHooks(server, {callback =>
            captured[0] = callback
            capturedSet[0] = true
        })
        @Assert(capturedSet[0])
        @Assert(!server.isClosed())
        // 触发回调等价于收到 SIGTERM：服务器完成关闭
        captured[0]()
        @Assert(server.isClosed())
    }
}
