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
import std.sync.{AtomicBool, AtomicInt64}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.LogPosition
import fountain::f_mq.client.MQClient
import fountain::f_mq.base.MQFilter
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::fmq.manager.{MQManager, MQManagerArgs}
import fountain::fmq.meta.MetaStore
import fountain::fmq.queue.CursorStore
import fountain::fmq.test.TestDirs

class ServerPortAllocator {
    private static let next = AtomicInt64(27000)

    static func freePort(): UInt16 {
        var attempt = 0
        while (attempt < 200) {
            let port = UInt16(next.fetchAdd(1) % 60000)
            if (!isListening(port)) {
                return port
            }
            attempt++
        }
        throw Exception("cannot find a free port")
    }

    /** 该端口是否已有监听者：TCP 构造函数不建连，必须显式 `connect()`。 */
    static func isListening(port: UInt16): Bool {
        let probe = TcpSocket(IPSocketAddress("127.0.0.1", port))
        try {
            probe.connect()
            true
        } catch (_: Exception) {
            false
        } finally {
            try {
                probe.close()
            } catch (_: Exception) {
                ()
            }
        }
    }
}

@Test
class MQServerTest {
    /** 进程不再注册 `atExit`，整个类的临时目录在收尾时统一回收。 */
    @AfterAll
    static func removeTempDirs(): Unit {
        TestDirs.cleanNamespace("server")
    }

    private static func options(root: String, port: UInt16, nodes: Array<String>,
        selfIndex!: Int64 = 0): MQServerOptions {
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        MQServerOptions(port, nodes, selfIndex, Duration.second * 10, 3, Duration.hour * 72,
            "${root}/logs", "${root}/dead", 1024 * 1024, Duration.hour * 72, 0, "${root}/metas")
    }

    private static func canConnect(port: UInt16): Bool {
        ServerPortAllocator.isListening(port)
    }

    private static func waitReady(port: UInt16): Unit {
        var ready = false
        var tries = 0
        while (!ready && tries < 300) {
            ready = canConnect(port)
            if (!ready) {
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

    /** 构造 `MQServer` 不绑定端口；只有 `start()` 才监听（R4-G2）。 */
    @TestCase
    public func portIsNotBoundBeforeStart(): Unit {
        let root = TestDirs.of("server", "deferred_bind")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        try {
            @Assert(!canConnect(port))
            server.start()
            waitReady(port)
            @Assert(canConnect(port))
        } finally {
            server.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    /** 定时器启动早于端口绑定：监听前端口一律拒绝连接（R4-G2）。 */
    @TestCase
    public func timersStartBeforePortBinding(): Unit {
        let root = TestDirs.of("server", "timer_first")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        let reached = AtomicBool(false)
        let refusedAtHook = AtomicBool(false)
        server.beforeBind = {=>
            reached.store(true)
            if (!canConnect(port)) {
                refusedAtHook.store(true)
            }
        }
        try {
            server.start()
            @Assert(reached.load())
            @Assert(refusedAtHook.load())
            waitReady(port)
        } finally {
            server.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    /** 装配期抛错不占端口：构造失败后端口仍闲置（R4-G2）。 */
    @TestCase
    public func assemblyFailureLeavesPortFree(): Unit {
        let root = TestDirs.of("server", "assembly_failure")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let port = ServerPortAllocator.freePort()
        // 节点下标越界：装配期（NodeRegistry）必然抛错
        let opts = options(root, port, ["127.0.0.1:${port}"], selfIndex: 5)
        var threw = false
        try {
            MQServer(opts)
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw)
        @Assert(!canConnect(port))
        remove(root, recursive: true)
    }

    /** 关闭步骤与规格顺序一致，且 `queues.sync` 独立执行一次（R4-G18）。 */
    @TestCase
    public func closeSyncsQueuesExactlyOnce(): Unit {
        let root = TestDirs.of("server", "close_sync")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        let syncs = AtomicInt64(0)
        server.syncQueuesOverride = {=> syncs.fetchAdd(1)}
        try {
            server.start()
            waitReady(port)
            let names = ArrayList<String>()
            for ((name, _) in server.closeSteps()) {
                names.add(name)
            }
            @Assert(String.join(names.toArray(), delimiter: ",") ==
                "server,cleanupTimer,antiEntropy,backup,cleaner,consume,subscribers,backupStore," +
                "queues.sync,queues,deadLetter,meta,registry")
            server.close()
            @Assert(syncs.load() == 1)
        } finally {
            server.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
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

    /** 离线期间被删除的主题：重启后队列目录、游标文件、订阅与计数器都不得残留（A25）。 */
    @TestCase
    public func restartCleansStateOfTopicDeletedWhileOffline(): Unit {
        let root = TestDirs.of("server", "offline_delete")
        let port = ServerPortAllocator.freePort()
        let options = options(root, port, ["127.0.0.1:${port}"])
        // 模拟上一次运行留下的盘上状态：主题/组元数据、队列段目录、游标位点
        let meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        meta.applyGroup(MQSubscribeGroupMeta("/t", "g"))
        let queueDir = "${root}/logs/%2Ft/0"
        Directory.create(queueDir, recursive: true)
        CursorStore("${root}/metas").save("/t", 0, "g", LogPosition(1, 0))
        @Assert(exists(queueDir))
        @Assert(exists("${root}/metas/offsets/%2Ft/0/g.cursor"))
        // 离线期间被删：只剩墓碑
        @Assert(meta.removeTopic("/t").size > 0)
        meta.close()

        let server = MQServer(options)
        try {
            @Assert(!exists("${root}/logs/%2Ft"))
            @Assert(!exists("${root}/metas/offsets/%2Ft"))
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

    // ===== 断链清理（A55/A60/A70） =====

    /** 断链巡检：移除订阅并释放其名下记录，同组其它订阅下一次消费即可取到。 */
    @TestCase
    public func cleanupSubscribersRemovesAndReleases(): Unit {
        let root = TestDirs.of("server", "cleanup_release")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        try {
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 1) == 0)
            @Assert(registerGroup(address, "/t", "g") == 0)
            let first = MQClient([address])
            let sid = first.subscribe("/t", subscribeGroup: "g")
            first.publish("/t", "held")
            let message = first.consume(sid)
            @Assert(message.get<String>() == Some("held"))
            // 断开连接：服务端连接关闭，但订阅表要等巡检才清
            first.close()
            var disconnected = false
            var tries = 0
            while (!disconnected && tries < 300) {
                for (info in server.subscriptionRegistry.infos()) {
                    if (info.subscribedId == sid && info.isDisconnected()) {
                        disconnected = true
                    }
                }
                sleep(Duration.millisecond * 10)
                tries++
            }
            @Assert(disconnected)
            server.cleanupSubscribers()
            @Assert(server.subscriptionRegistry.infos().size == 0)
            // 记录被退回组内：同组的新订阅下一次消费即可取到
            let second = MQClient([address])
            try {
                let other = second.subscribe("/t", subscribeGroup: "g")
                let delivered = second.consume(other)
                @Assert(delivered.get<String>() == Some("held"))
                second.ack(other, delivered.queueIndex, delivered.segmentedIndex, delivered.segmentedOffset)
            } finally {
                second.close()
            }
        } finally {
            server.close()
        }
    }

    /** 巡检期间同一 subscribedId 重订阅（连接恢复）：清理不得删掉新订阅。 */
    @TestCase
    public func cleanupSubscribersKeepsResubscribed(): Unit {
        let root = TestDirs.of("server", "cleanup_resubscribe")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        try {
            let dead = MQSubscriptionInfo("s1", "/t", "g", [], MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER,
                alive: {=> false})
            @Assert(server.subscriptionRegistry.register(dead).code == 0)
            server.cleanupSubscribers()
            @Assert(server.subscriptionRegistry.infos().size == 0)
            // 同一 id 在清理快照之后重订阅：代次自增，旧快照不得摘掉它
            let live = MQSubscriptionInfo("s1", "/t", "g", [], MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER,
                alive: {=> true})
            @Assert(server.subscriptionRegistry.register(live).code == 0)
            server.cleanupSubscribers()
            @Assert(server.subscriptionRegistry.infos().size == 1)
        } finally {
            server.close()
        }
    }

    /** 断链即释放：清理器摘除死连接订阅后，同组另一订阅下一次消费取到记录（R2-G4）。 */
    @TestCase
    public func cleanupSubscribersReleasesRecordToGroup(): Unit {
        let root = TestDirs.of("server", "cleanup_buffer")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        try {
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 1) == 0)
            @Assert(registerGroup(address, "/t", "g") == 0)
            let first = MQClient([address])
            let sid = first.subscribe("/t", subscribeGroup: "g")
            first.publish("/t", "held")
            let message = first.consume(sid)
            @Assert(message.get<String>() == Some("held"))

            // 连接断开回调等价路径：把该订阅标成「连接已死」后交给清理器
            var found = false
            for (info in server.subscriptionRegistry.infos()) {
                if (info.subscribedId == sid) {
                    server.subscriptionRegistry.register(MQSubscriptionInfo(info.subscribedId, info.topic,
                        info.subscribeGroup, [], MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER,
                        alive: {=> false}))
                    found = true
                }
            }
            @Assert(found)
            server.cleanupSubscribers()
            @Assert(server.subscriptionRegistry.infos().size == 0)

            // 记录已退回组内：新订阅立刻拿到
            let second = MQClient([address])
            try {
                let other = second.subscribe("/t", subscribeGroup: "g")
                let delivered = second.consume(other)
                @Assert(delivered.get<String>() == Some("held"))
                second.ack(other, delivered.queueIndex, delivered.segmentedIndex, delivered.segmentedOffset)
            } finally {
                second.close()
                first.close()
            }
        } finally {
            server.close()
        }
    }

    /** 关闭时清空订阅表：进程内重启不残留旧订阅。 */
    @TestCase
    public func closeClearsSubscriptionTable(): Unit {
        let root = TestDirs.of("server", "close_subscribers")
        let port = ServerPortAllocator.freePort()
        let server = MQServer(options(root, port, ["127.0.0.1:${port}"]))
        try {
            server.start()
            waitReady(port)
            let address = "127.0.0.1:${port}"
            @Assert(register(address, "/t", 1) == 0)
            @Assert(registerGroup(address, "/t", "g") == 0)
            let client = MQClient([address])
            let sid = client.subscribe("/t", subscribeGroup: "g")
            @Assert(server.subscriptionRegistry.infos().size == 1)
            server.close()
            @Assert(server.subscriptionRegistry.infos().size == 0)
            client.close()
        } finally {
            server.close()
        }
    }
}
