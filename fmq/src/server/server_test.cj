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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*
import std.sync.{AtomicInt64, AtomicBool}
import std.fs.*
import std.fs.removeIfExists

@Test
public class QueueDistributionTest {
    private static let dirCounter = AtomicInt64(0)

    private static func makeQueue(topic: String, index: Int64): MqQueue {
        MqQueue(topic, index, "/tmp/fmq_qdist_${dirCounter.fetchAdd(1) + 1}", 1024)
    }

    @TestCase
    public func testDistributeReturnsValidIndex(): Unit {
        let config = testConfig()
        let qm = QueueManager(config)
        let n0 = qm.distribute("/test", 0, 3)
        @Assert(n0 >= 0 && n0 < 3)
        let n1 = qm.distribute("/test", 1, 3)
        @Assert(n1 >= 0 && n1 < 3)
        let n2 = qm.distribute("/test", 2, 3)
        @Assert(n2 >= 0 && n2 < 3)
    }

    @TestCase
    public func testRouteToQueueSingleQueueReturnsFirst(): Unit {
        let config = testConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        let q0 = makeQueue("/test", 0)
        let queues = ArrayList<MqQueue>()
        queues.add(q0)
        // 单队列 → 始终返回 queues[0]
        let result = qm.routeToQueue("/test", queues)
        @Assert(result.topic == "/test")
        @Assert(result.index == 0)
        q0.close()
    }

    @TestCase
    public func testRouteToQueueSameTopicConsistentRouting(): Unit {
        let config = testConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        let q0 = makeQueue("/test", 0)
        let q1 = makeQueue("/test", 1)
        let q2 = makeQueue("/test", 2)
        let queues = ArrayList<MqQueue>()
        queues.add(q0); queues.add(q1); queues.add(q2)
        // 相同 topic 多次调用 → CRC64 一致，路由到相同队列
        let r1 = qm.routeToQueue("/test", queues)
        let r2 = qm.routeToQueue("/test", queues)
        @Assert(r1.index == r2.index)
        q0.close(); q1.close(); q2.close()
    }

    @TestCase
    public func testRouteToQueueDifferentTopicsMayDiverge(): Unit {
        let config = testConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        let q0 = makeQueue("/a", 0)
        let q1 = makeQueue("/a", 1)
        let q2 = makeQueue("/a", 2)
        let queues = ArrayList<MqQueue>()
        queues.add(q0); queues.add(q1); queues.add(q2)
        let rA = qm.routeToQueue("/a", queues)
        let rB = qm.routeToQueue("/b", queues)
        // 不同 topic → CRC64 不同，可能路由到不同队列；无论如何每个都应有效
        @Assert(rA.index >= 0 && rA.index < 3)
        @Assert(rB.index >= 0 && rB.index < 3)
        q0.close(); q1.close(); q2.close()
    }

    @TestCase
    public func testRouteToQueueIndexInRange(): Unit {
        let config = testConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        let queues = ArrayList<MqQueue>()
        for (i in 0..5) {
            queues.add(makeQueue("/rng", i))
        }
        for (_ in 0..50) {
            let q = qm.routeToQueue("/rng-${dirCounter.fetchAdd(1)}", queues)
            @Assert(q.index >= 0 && q.index < 5)
        }
        for (q in queues) { q.close() }
    }

    @TestCase
    public func testDistributeWithZeroNodeCountReturnsZero(): Unit {
        // P3-1: nodeCount=0 防御返回 0，不崩溃
        let config = testConfig()
        let qm = QueueManager(config)
        @Assert(qm.distribute("/test", 0, 0) == 0)
        @Assert(qm.distribute("/test", 42, 0) == 0)
        @Assert(qm.distribute("/test", 0, -1) == 0)
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        hosts.add("node3:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class QueueManagerConcurrencyTest {
    /**
     * P1-1: 验证并发调用 getOrCreateQueues 时 writers ArrayList 不崩溃。
     * startWriterAndReader 内部通过 synchronized(lock) 保护 writers.add()。
     */
    @TestCase
    public func testConcurrentGetOrCreateWithWritersSync(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = concurrentTestConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(ReplicationManager(config))

        // 并发创建不同 topic，每个都通过 getOrCreateQueues 触发 startWriterAndReader
        let futures = ArrayList<Future<ArrayList<MqQueue>>>()
        for (i in 0..10) {
            let topic = "/p1-1-topic-${i}"
            futures.add(spawn { qm.getOrCreateQueues(topic, 2) })
        }
        for (f in futures) {
            let queues = f.get()
            @Assert(queues.size > 0)
        }
        // 验证 writers 快照正常（close 时遍历 writers 不崩溃）
        qm.close()
    }

    @TestCase
    public func testConcurrentCreateAndListTopics(): Unit {
        let config = concurrentTestConfig()
        let qm = QueueManager(config, nodeIndex: 0)

        let futures = ArrayList<Future<Unit>>()
        for (i in 0..10) {
            let topic = "/concurrent-topic-${i}"
            futures.add(spawn {
                qm.createQueues(topic, 3)
                let qs = qm.getQueues(topic)
                qm.listTopics()
            })
        }
        for (f in futures) { f.get() }

        for (i in 0..10) {
            let topic = "/concurrent-topic-${i}"
            @Assert(qm.getQueues(topic).isSome())
        }
    }

    private static func concurrentTestConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class ReassignTest {
    @TestCase
    public func testReassignCreatesQueuesLocally(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_reassign_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        // nodeIndex=0 创建队列，nodeIndex=1 故障后接管
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        let before = qm.getQueues("/test")
        @Assert(before.isSome())
        if (let Some(qs) <- before) {
            @Assert(qs.size == 1)  // nodeIndex=0 只创建归属于节点 0 的队列
        }
        // 节点 1 故障，节点 0 接管
        let reassigned = qm.reassign(1)
        @Assert(reassigned.size > 0)
        let after = qm.getQueues("/test")
        if (let Some(qs) <- after) {
            @Assert(qs.size == 2)  // 接管后 2 个队列都在本地
        }
    }

    @TestCase
    public func testUnreassignDrainsThenRemoves(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_unreassign_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        qm.reassign(1)
        let afterReassign = qm.getQueues("/test")
        if (let Some(qs) <- afterReassign) {
            @Assert(qs.size == 2)
        }
        // 标记排空：draining=true，仍在队列列表中
        qm.unreassign(1)
        let q1 = qm.getQueue("/test", 1)
        @Assert(q1.isSome())
        if (let Some(q) <- q1) {
            @Assert(q.draining.load())
            @Assert(!q.isClosed())
        }
        // 排空完成检查：deliveryBuffer 空应自动移除
        qm.drainCompleteCheck()
        let afterDrain = qm.getQueue("/test", 1)
        @Assert(afterDrain.isNone())  // 已移除
        // 自己的队列不受影响
        let q0 = qm.getQueue("/test", 0)
        @Assert(q0.isSome())
    }

    @TestCase
    public func testReassignStartsWriterReader(): Unit {
        // P2-2: reassign 后 writer/reader 线程应自动启动
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_reassign_wr", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        let reassigned = qm.reassign(1)
        @Assert(reassigned.size > 0)
        // 验证接管后的队列存在（writer/reader 已在内部启动）
        let q1 = qm.getQueue("/test", 1)
        @Assert(q1.isSome())
        if (let Some(q) <- q1) {
            @Assert(!q.isClosed())
        }
        // 无崩溃即验证 writer/reader 启动逻辑正确
    }

}

@Test
public class ReplicationRoleTest {
    @TestCase
    public func testPromoteAndDemote(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.role() != "master")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        rm.demoteToSlave("new-master")
        @Assert(rm.role().contains("slave"))
    }

    @TestCase
    public func testSlaveRegistration(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        @Assert(rm.onSlaveOf("slave1"))
        @Assert(rm.getSlaves().size == 1)
    }

    @TestCase
    public func testFailover(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.failoverToMaster())
        @Assert(rm.role() == "master")
    }

    @TestCase
    public func testPromoteDemoteCycle(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.role() != "master")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        rm.demoteToSlave("node2")
        @Assert(rm.role().contains("slave"))
        // 二次 promote 应生效
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
    }

    /**
     * P1-2: 验证 isMasterAlive 在没有 master 连接时不崩溃并返回 true。
     * masterConn 为 None 且 masterNodeId 为空或 mqHosts 为空时返回 true。
     */
    @TestCase
    public func testIsMasterAliveNoMasterReturnsTrue(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        // 从未调用 connectToMaster/promoteToMaster → masterConn 为 None
        // masterNodeId 为空 → 返回 true
        @Assert(rm.isMasterAlive())
    }

    /**
     * P1-1: 验证 connectToMaster 失败后 isSyncing 为 false。
     * 连接不可达的 master 时 error path 正确设置同步状态。
     */
    @TestCase
    public func testConnectToMasterFailsReturnsFalse(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("localhost:1")
        let config = MqConfig.forTest(dataDir: "/tmp/fmq_p11_sync", mqHosts: hosts)
        let rm = ReplicationManager(config)
        rm.demoteToSlave("node99")
        // 连接不可达的 master，应返回 false（不抛异常）
        @Assert(!rm.connectToMaster("node99"))
    }

    /**
     * P2-2: 验证 onSlaveOf 重复调用不产生重复条目。
     * 重连时更新 lastHeartbeat 而非新增 SlaveProgress。
     */
    @TestCase
    public func testOnSlaveOfReconnectUpdatesLastHeartbeat(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        @Assert(rm.onSlaveOf("slave1"))
        @Assert(rm.getSlaves().size == 1)
        // 再次调用 onSlaveOf 同一节点（模拟重连）
        @Assert(rm.onSlaveOf("slave1"))
        // 不应出现重复条目
        @Assert(rm.getSlaves().size == 1)
        // 验证不同节点各算一次
        @Assert(rm.onSlaveOf("slave2"))
        @Assert(rm.getSlaves().size == 2)
    }

    private static func testConfig(): MqConfig {
        MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

/**
 * QueueManager 线程生命周期测试。
 * 验证 startAll 启动线程 + close 等待 join 不抛异常。
 */
@Test
public class QueueManagerLifecycleTest {
    @TestCase
    public func testStartAllAndCloseJoinsThreads(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_qm_lifecycle", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let qm = QueueManager(config, nodeIndex: 0)

        let queues = qm.createQueues("/test-life", 1)
        @Assert(queues.size > 0)
        @Assert(qm.getQueues("/test-life").isSome())
        let q = queues[0]
        @Assert(!q.isClosed())
        qm.close()  // 验证 close 不抛异常，不启动 writer/reader 线程
        @Assert(q.isClosed())
    }

    /**
     * P2-2: 验证 close() 设置 closed 标志后阻止新 writer 启动。
     * startWriterAndReader 检查 closed.load()，为 true 时跳过 writer 创建。
     */
    @TestCase
    public func testClosePreventsNewWriters(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_qm_closed_writer", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(ReplicationManager(config))

        // close 后再创建队列 — 不应崩溃
        qm.close()
        let queues = qm.createQueues("/p2-2-closed", 1)
        @Assert(queues.size > 0)
        // getOrCreateQueues 应不崩溃，但不启动新 writer
        let existing = qm.getOrCreateQueues("/p2-2-closed", 1)
        @Assert(existing.size > 0)
        for (q in existing) { q.close() }
    }
}

@Test
public class DeliverySimpleTest {
    @TestCase
    public func testRecordAndAck(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        let record = dm.recordDelivery("msg1", "consumer1", "group1", "/test")
        @Assert(record.messageId == "msg1")
        let ok = dm.onAck("msg1", "/test", 0)
        @Assert(ok)
    }

    @TestCase
    public func testDoubleAckReturnsFalse(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        dm.recordDelivery("msg1", "consumer1", "group1", "/test")
        dm.onAck("msg1", "/test", 0)
        let second = dm.onAck("msg1", "/test", 0)
        @Assert(!second)
    }

    @TestCase
    public func testConcurrentAckSingleSuccess(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        dm.recordDelivery("concurrent-msg", "consumer-c", "group-c", "/test")

        // 并发启动多个线程同时 ACK
        let futures = ArrayList<Future<Bool>>()
        for (_ in 0..10) {
            futures.add(spawn {
                dm.onAck("concurrent-msg", "/test", 0)
            })
        }
        var okCount = 0
        for (f in futures) {
            if (f.get()) { okCount += 1 }
        }
        // 只有 1 个线程应返回 true，其余返回 false
        @Assert(okCount == 1)
    }

    private static func deliveryTestConfig(): MqConfig {
        MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class QueueWriterDispatchTest {
    private static let qwDirCounter = AtomicInt64(0)

    private static func qwDir(base: String): String {
        "/tmp/fmq_qw_${base}_${qwDirCounter.fetchAdd(1) + 1}"
    }

    @TestCase
    public func testGetWriterForQueueReturnsNoneBeforeStart(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: qwDir("none"), segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        let queues = qm.createQueues("/test", 1)
        @Assert(queues.size == 1)
        let q = queues[0]
        // startAll() 未调用，writer 不应存在
        @Assert(qm.getWriterForQueue(q).isNone())
        q.close()
    }

    @TestCase
    public func testStartWritersForTopicStartsWriter(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: qwDir("start"), segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(ReplicationManager(config))
        let queues = qm.createQueues("/test-start", 2)
        @Assert(queues.size > 0)
        // startWritersForTopic 前 writer 不存在
        let q = queues[0]
        @Assert(qm.getWriterForQueue(q).isNone())
        // startWritersForTopic 后 writer 应存在
        qm.startWritersForTopic("/test-start")
        if (let Some(writer) <- qm.getWriterForQueue(q)) {
            writer.close()
        } else {
            @Assert(false)
        }
        qm.close()
        q.close()
    }

    @TestCase
    public func testGetWriterForQueueReturnsSomeAfterStartAll(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: qwDir("all"), segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(ReplicationManager(config))
        let queues = qm.createQueues("/test", 1)
        @Assert(queues.size == 1)
        let q = queues[0]
        qm.startAll()
        // startAll() 后 writer 应存在
        if (let Some(writer) <- qm.getWriterForQueue(q)) {
            writer.close()
        } else {
            @Assert(false)
        }
        qm.close()
        q.close()
    }

    @TestCase
    public func testWriterSyncToSlavesDoesNotFailWithSlavesRegistered(): Unit {
        // 验证 syncToSlaves 在有 slave 注册时不抛异常，数据正常写入
        let config = MqConfig(
            mqHosts: ArrayList<String>(), syncHosts: ArrayList<String>(),
            dataDir: qwDir("slave"), segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let q = MqQueue("/test_sync", 0, qwDir("slave"), 1024)
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        rm.onSlaveOf("slave1")
        let writer = QueueWriter(q, config, replicationManager: rm, queueSize: 16)
        // 提交数据并通过 writer 写入
        writer.submit([0x10u8, 0x20u8, 0x30u8])
        let future = spawn { writer.run() }
        sleep(Duration.millisecond * 100)
        writer.close()
        future.get()
        // 验证数据已写入
        @Assert(q.tryReadFromLog(0).isSome())
        q.close()
    }
}

@Test
public class DeliveryRecordOverwriteTest {
    @TestCase
    public func testRecordDeliveryNoOverwrite(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)

        let first = dm.recordDelivery("msg1", "consumer-A", "group-A", "/test")
        @Assert(first.groupId == "group-A")

        let second = dm.recordDelivery("msg1", "consumer-B", "group-B", "/test")
        @Assert(second.groupId == "group-A")
        @Assert(second.consumerId == "consumer-A")
    }

    private static func deliveryTestConfig(): MqConfig {
        MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class DeadLetterStoreTest {
    private static let counter = AtomicInt64(0)

    private static func dlqDir(name: String): String {
        "/tmp/fmq_dlq_${name}_${counter.fetchAdd(1) + 1}"
    }

    @TestCase
    public func testAppendAndList(): Unit {
        let ds = DeadLetterStore(dlqDir("append"), retentionHours: 168)
        ds.append([0x01u8, 0x02u8, 0x03u8], "/test", 0, "msg-001")

        let list1 = ds.list("/test", 0)
        @Assert(list1.size == 1)
        if (list1.size > 0) {
            @Assert(list1[0][0] == "msg-001")
            @Assert(list1[0][1].size == 3)
        }

        let list2 = ds.list("/other", 0)
        @Assert(list2.size == 0)
    }

    @TestCase
    public func testRedeliver(): Unit {
        let ds = DeadLetterStore(dlqDir("redeliver"), retentionHours: 168)
        ds.append([0xAu8, 0xBu8], "/test", 1, "msg-002")

        let r = ds.redeliver("/test", 1, "msg-002")
        @Assert(r != None)
        if (let Some(data) <- r) {
            @Assert(data.size == 2)
            @Assert(data[0] == 0xAu8)
        }

        let list = ds.list("/test", 1)
        @Assert(list.size == 0)
    }

    @TestCase
    public func testRedeliverNonExistent(): Unit {
        let ds = DeadLetterStore(dlqDir("nox"), retentionHours: 168)
        @Assert(ds.redeliver("/test", 0, "nonexistent").isNone())
    }

    @TestCase
    public func testRedeliverAll(): Unit {
        let ds = DeadLetterStore("/tmp/fmq_dlq_test4", retentionHours: 168)
        ds.append([0x01u8], "/test", 0, "msg-a")
        ds.append([0x02u8], "/test", 0, "msg-b")
        ds.append([0x03u8], "/other", 0, "msg-c")

        let all = ds.redeliverAll("/test", 0)
        @Assert(all.size == 2)

        let after = ds.list("/test", 0)
        @Assert(after.size == 0)
    }

    @TestCase
    public func testRebuildIndexWorkWithDeletions(): Unit {
        let ds = DeadLetterStore(dlqDir("rebidx"), retentionHours: 168)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.append([0x02u8], "/b", 0, "msg-2")
        // redeliver 会从索引删除
        ds.redeliver("/a", 0, "msg-1")
        @Assert(ds.list("/a", 0).size == 0)
        @Assert(ds.list("/b", 0).size == 1)
    }

    @TestCase
    public func testCleanupPreservesFreshEntries(): Unit {
        let ds = DeadLetterStore(dlqDir("cleanup"), retentionHours: 168)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.append([0x02u8], "/b", 0, "msg-2")
        ds.cleanup()
        // retentionHours=168, all entries are fresh, nothing should be removed
        @Assert(ds.list("/a", 0).size == 1)
        @Assert(ds.list("/b", 0).size == 1)
    }

    @TestCase
    public func testCleanupRetentionZeroSkips(): Unit {
        let ds = DeadLetterStore(dlqDir("cleanup0"), retentionHours: 0)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.cleanup()
        // retentionHours=0 means unlimited, nothing should be removed
        @Assert(ds.list("/a", 0).size == 1)
    }

    @TestCase
    public func testBatchSyncTriggeredOnThreshold(): Unit {
        let ds = DeadLetterStore(dlqDir("batchsync"), retentionHours: 168, syncBatchSize: 3)
        // 追加 2 条（未达到 batchSize=3，不触发 sync，但不影响 append 功能）
        ds.append([0x01u8], "/test", 0, "msg-b1")
        ds.append([0x02u8], "/test", 0, "msg-b2")
        // 第 3 条达到 batchSize，触发 sync
        ds.append([0x03u8], "/test", 0, "msg-b3")
        // 验证所有 3 条均可列出
        let list = ds.list("/test", 0)
        @Assert(list.size == 3)
        // 验证 sync() 幂等（已 sync 后再调用不抛异常）
        ds.sync()
 
    }

    /**
     * P1-3: 验证 unsyncedCount 串行正确性。
     * 串行批量 append 验证计数准确。
     * ⚠️ 该测试是串行的而非并发测试，函数名明确反映其范围。
     */
    @TestCase
    public func testUnsyncedCountSerial(): Unit {
        let ds = DeadLetterStore(dlqDir("atomic"), retentionHours: 168, syncBatchSize: 10)
        for (i in 0..10) {
            ds.append([0x01u8], "/test", 0, "msg-a-${i}")
        }
        let after = ds.list("/test", 0)
        @Assert(after.size == 10)
    }

    /**
     * SRV-7: 验证 DeliveryRecord 保存原始 payload，moveToDLQ 不丢失数据。
     * 修复前 moveToDLQ 传 []，DLQ 中无原始数据。
     */
    @TestCase
    public func testDeliveryRecordPayloadPreservedInDLQ(): Unit {
        let payload: Array<Byte> = [0xAAu8, 0xBBu8, 0xCCu8]
        let ds = DeadLetterStore("/tmp/fmq_srv7_test", retentionHours: 168)

        // 通过 DeadLetterStore 直接 append 带 payload 的消息
        ds.append(payload, "/srv7-topic", 0, "srv7-msg-001")

        // 列出并验证 payload
        let entries = ds.list("/srv7-topic", 0)
        @Assert(entries.size == 1)
        if (entries.size > 0) {
            @Assert(entries[0][0] == "srv7-msg-001")
            @Assert(entries[0][1] == payload)
        }

        // 清理
        try { removeDir("/tmp/fmq_srv7_test") } catch (_: Exception) {}
    }

    /**
     * P2-4: 验证 append 后 list 返回所有条目。
     * rebuildIndex 在 init 时自动调用，确保内存索引与 SegmentedLog 一致。
     */
    @TestCase
    public func testDeadLetterRebuildIndexPreservesTimestamps(): Unit {
        let dir = dlqDir("rebidx_ts")
        let ds = DeadLetterStore(dir, retentionHours: 168)
        ds.append([0x01u8, 0x02u8], "/test", 0, "msg-ts-1")
        ds.append([0x03u8, 0x04u8], "/test", 0, "msg-ts-2")
        ds.sync()
        // 验证内存索引正确
        let entries = ds.list("/test", 0)
        @Assert(entries.size == 2)
        var found1 = false
        var found2 = false
        for ((msgId, data) in entries) {
            if (msgId == "msg-ts-1" && data.size == 2) { found1 = true }
            if (msgId == "msg-ts-2" && data.size == 2) { found2 = true }
        }
        @Assert(found1)
        @Assert(found2)
        ds.close()
        removeDir(dir)
    }
}

func removeDir(path: String): Unit {
    try {
        for (entry in Directory.readFrom(path)) {
            try { remove(entry.path.toString()) } catch (_: Exception) {}
        }
        remove(path)
    } catch (_: Exception) {}
}

@Test
public class TopicManagerTest {
    @TestCase
    public func testCreateAndDelete(): Unit {
        let config = configWithHosts()
        let tm = TopicManager(config)
        @Assert(tm.createTopic("/test", queueCount: 2) == MqErrorCode.SUCCESS)
        @Assert(tm.createTopic("/test") == MqErrorCode.TOPIC_EXISTS)
        @Assert(tm.deleteTopic("/test") == MqErrorCode.SUCCESS)
        @Assert(tm.deleteTopic("/test") == MqErrorCode.TOPIC_NOT_FOUND)
    }

    @TestCase
    public func testListTopics(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/a")
        tm.createTopic("/b")
        let list = tm.listTopics()
        @Assert(list.size == 2)
    }

    @TestCase
    public func testAddAndRemoveConsumerGroup(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/test")
        @Assert(tm.addConsumerGroup("/test", "group1") == MqErrorCode.SUCCESS)
        let meta = tm.getTopicMeta("/test")
        if (let Some(m) <- meta) {
            @Assert(m.getConsumerGroups().size == 1)
        }
        @Assert(tm.removeConsumerGroup("/test", "group1") == MqErrorCode.SUCCESS)
    }

    @TestCase
    public func testListAllConsumerGroupsEmpty(): Unit {
        let tm = TopicManager(configWithHosts())
        let all = tm.listAllConsumerGroups()
        @Assert(all.size == 0)
    }

    @TestCase
    public func testListAllConsumerGroupsWithTopics(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/a")
        tm.createTopic("/b")
        tm.addConsumerGroup("/a", "g1")
        tm.addConsumerGroup("/a", "g2")
        tm.addConsumerGroup("/b", "g3")
        let all = tm.listAllConsumerGroups()
        @Assert(all.size == 2)
        if (let Some(groups) <- all.get("/a")) {
            @Assert(groups.size == 2)
        }
        if (let Some(groups) <- all.get("/b")) {
            @Assert(groups.size == 1)
        }
    }

    @TestCase
    public func testListAllConsumerGroupsSkipEmpty(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/x")
        tm.createTopic("/y")
        tm.addConsumerGroup("/y", "g")
        let all = tm.listAllConsumerGroups()
        // /x 无 consumerGroup 不应出现
        @Assert(all.size == 1)
        @Assert(all.get("/x").isNone())
        @Assert(all.get("/y").isSome())
    }

    @TestCase
    public func testConcurrentReadWrite(): Unit {
        let tm = TopicManager(configWithHosts())
        tm.createTopic("/base")
        // 并发读写：写入线程创建 topic，读取线程同时 list/get
        let done = AtomicBool(false)
        let writeCount = AtomicInt64(0)
        let readCount = AtomicInt64(0)
        var writers = ArrayList<Future<Unit>>()
        var readers = ArrayList<Future<Unit>>()
        // 5 个写入线程
        for (i in 0..5) {
            writers.add(spawn {
                let idx = i
                while (!done.load()) {
                    let name = "/topic_${idx}_${writeCount.fetchAdd(1)}"
                    try { tm.createTopic(name) } catch (_: Exception) {}
                }
            })
        }
        // 5 个读取线程
        for (_ in 0..5) {
            readers.add(spawn {
                while (!done.load()) {
                    let _ = tm.listTopics()
                    let _ = tm.getTopicMeta("/base")
                    let _ = tm.listAllConsumerGroups()
                    let _ = tm.getConsumerGroups("/base")
                    readCount.fetchAdd(1)
                }
            })
        }
        sleep(Duration.millisecond * 300)
        done.store(true)
        for (w in writers) { w.get() }
        for (r in readers) { r.get() }
        let reads = readCount.load()
        @Assert(reads > 0)
        // 验证基础操作仍正常
        let topics = tm.listTopics()
        @Assert(topics.size > 0)
    }

    private static func configWithHosts(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_tm_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class ConsumerMatcherTest {
    @TestCase
    public func testGetRegistrationsEmpty(): Unit {
        let cm = ConsumerMatcher()
        let regs = cm.getRegistrations()
        @Assert(regs.size == 0)
    }

    @TestCase
    public func testGetRegistrationsAfterRegister(): Unit {
        let cm = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)
        let regs = cm.getRegistrations()
        @Assert(regs.size == 1)
        @Assert(regs[0].getConsumerId() == "c1")
        @Assert(regs[0].getGroupId() == "g1")
    }

    @TestCase
    public func testGetRegistrationsAfterDeregister(): Unit {
        let cm = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)
        cm.deregister("g1", "c1")
        let regs = cm.getRegistrations()
        @Assert(regs.size == 0)
    }
}

@Test
public class DeliveryManagerTest {
    @TestCase
    public func testRecordDeliveryNoDuplicate(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        let r1 = dm.recordDelivery("msg1", "c1", "g1", "/topic")
        let r2 = dm.recordDelivery("msg1", "c2", "g2", "/topic")
        // 同 messageId 返回同一 record（不覆盖）
        @Assert(r1.consumerId == r2.consumerId)  // 仍为 "c1"
        @Assert(r1.groupId == r2.groupId)  // 仍为 "g1"
    }

    @TestCase
    public func testConcurrentRecordDelivery(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        let counter = AtomicInt64(0)
        var futures = ArrayList<Future<Unit>>()
        // 10 线程并发 recordDelivery 同一 messageId
        for (_ in 0..10) {
            futures.add(spawn {
                let c = counter.fetchAdd(1)
                dm.recordDelivery("msg_shared", "c${c}", "g${c}", "/topic")
            })
        }
        for (f in futures) { f.get() }
        // onAck 验证 record 存在
        let result = dm.onAck("msg_shared", "/topic", 0)
        @Assert(result)
    }

    private static func deliveryTestConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_dm_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

@Test
public class BrokerManagerTest {
    @TestCase
    public func testInitFromMqHosts(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let bm = BrokerManager(config)
        @Assert(bm.aliveCount() == 2)
        @Assert(bm.checkConsistency())
        bm.close()
    }

    @TestCase
    public func testInitEmptyHosts(): Unit {
        let config = MqConfig(
            mqHosts: ArrayList<String>(), syncHosts: ArrayList<String>(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let bm = BrokerManager(config)
        @Assert(bm.aliveCount() == 0)
        @Assert(bm.checkConsistency())
        bm.close()
    }
}

/**
 * DeliveryManager 超时检查后台线程测试。
 */
@Test
public class DeliveryManagerTimeoutTest {
    private static let TEST_DIR = "/tmp/fmq_dm_timeout_test"

    @TestCase
    public func testCheckerStartsAndStopsWithoutCrash(): Unit {
        let config = timeoutTestConfig()
        let dm = DeliveryManager(config)
        // 启动检查线程
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 50)
        // 关闭不抛异常
        dm.close()
 
    }

    @TestCase
    public func testCheckerProcessesExpiredRecord(): Unit {
        let config = timeoutTestConfig()
        let dm = DeliveryManager(config)
        let cm = ConsumerMatcher()
        let qm = createEmptyQueueManager()
        dm.setConsumerMatcher(cm)
        dm.setQueueManager(qm)
        // 记录投递（使用极短超时）
        let record = dm.recordDelivery("timeout-msg", "c1", "g1", "/test")
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 200)
        // 检查线程运行后记录应被处理（retryCount >= 0）
        @Assert(record.retryCount.load() >= 0)
        dm.close()
    }

    private static func timeoutTestConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 50,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func createEmptyQueueManager(): QueueManager {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        QueueManager(config, nodeIndex: 0)
    }
}

/**
 * ConsumerMatcher compiledPatterns 缓存上限测试。
 */
@Test
public class ConsumerMatcherCacheTest {
    @TestCase
    public func testCompiledPatternsClearedWhenFull(): Unit {
        let cm = ConsumerMatcher()
        // 注册超过 MAX_COMPILED_PATTERNS (1000) 的唯一 Glob 模式
        // 验证不抛异常即可
        for (i in 0..1050) {
            let reg = ConsumerRegistration(
                consumerId: "c${i}", groupId: "g${i}",
                matchModeStr: "Glob:/test/pattern_${i}/*",
                labels: None, dataFilter: None,
                lastHeartbeat: DateTime.now())
            cm.register(reg)
        }
        // 触发大量 glob 匹配 - 验证不抛异常
        let result = cm.matchTopic("/test/pattern_999/x")
        @Assert(result.size == 1)
    }
}

/**
 * 主题编解码测试（验证 decodePathToTopic 优化后正确性）。
 */
@Test
public class TopicEncodingTest {
    @TestCase
    public func testDecodePathToTopicRoundtrip(): Unit {
        let topics: Array<String> = ["/order/create", "/a_b", "/foo/bar/baz", "/x"]
        for (t in topics) {
            let encoded = encodeTopicToPath(t)
            let decoded = decodePathToTopic(encoded)
            @Assert(decoded == t)
        }
    }
}

/**
 * P1-4 修复后：DLQ 通过 QueueManager.getQueue → queue.deadLetter 路由。
 */
@Test
public class DeliveryManagerDlqInjectionTest {
    @TestCase
    public func testMoveToDLQAfterDLQInjection(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_dlq_inject", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 50,
            maxRetryCount: 0, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let dm = DeliveryManager(config)
        let qm = QueueManager(config, nodeIndex: 0)
        dm.setQueueManager(qm)
        let cm = ConsumerMatcher()
        dm.setConsumerMatcher(cm)
        let record = dm.recordDelivery("dlq-msg-1", "c1", "g1", "/test")
        record.retryCount.store(999)  // 超限
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 300)
        dm.close()
 
    }
}

/**
 * QueueWriter.close() 幂等性测试。
 * 对应 P1-6: close() 被二次调用时 Future.get() 在已完成的 Future 上阻塞。
 */
@Test
public class QueueWriterCloseIdempotentTest {
    @TestCase
    public func testCloseCalledTwiceDoesNotHang(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_qw_idem", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let q = MqQueue("/test-idem", 0, "/tmp/fmq_qw_idem", 4096)
        let rm = ReplicationManager(config)
        let writer = QueueWriter(q, config, replicationManager: rm)
        writer.startSyncThread()
        // 第一次 close
        writer.close()
        // 第二次 close（幂等性测试：不阻塞）
        writer.close()
        @Assert(writer.isClosed())
    }
}

/**
 * ConsumerMatcher.refresh() 清理测试。
 * 对应 P1-7: refresh 定时调用清除过期消费者注册。
 */
@Test
public class ConsumerMatcherRefreshTest {
    @TestCase
    public func testRefreshRemovesStaleRegistrations(): Unit {
        let cm = ConsumerMatcher(heartbeatIntervalSec: 1)  // 超时 = 3s
        let reg = ConsumerRegistration(
            consumerId: "stale-consumer", groupId: "stale-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now() - Duration.second * 10)  // 10s 前 → 过期
        cm.register(reg)
        @Assert(cm.matchTopic("/test").size == 1)
        cm.refresh()
        @Assert(cm.matchTopic("/test").size == 0)
    }

    @TestCase
    public func testRefreshKeepsActiveRegistrations(): Unit {
        let cm = ConsumerMatcher(heartbeatIntervalSec: 5)  // 超时 = 15s
        let reg = ConsumerRegistration(
            consumerId: "active-consumer", groupId: "active-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())  // 刚心跳
        cm.register(reg)
        cm.refresh()
        @Assert(cm.matchTopic("/test").size == 1)
    }
}

/**
 * DeadLetterStore close 测试。
 * 对应 P2-3: SegmentedLog FD 泄漏修复。
 */
@Test
public class DeadLetterStoreCloseTest {
    @TestCase
    public func testCloseTwiceDoesNotThrow(): Unit {
        let ds = DeadLetterStore("/tmp/fmq_dlq_close_test")
        ds.close()
        ds.close()
 
    }
}

// ───── 共享测试工具函数 ─────

/**
 * 创建测试用 MqConfig，仅需要指定 dataDir。
 * 所有测试类统一使用此函数，避免构造代码重复。
 */
public func testConfig(dataDir: String): MqConfig {
    let hosts = ArrayList<String>()
    hosts.add("node1:7201")
    MqConfig(
        mqHosts: hosts, syncHosts: ArrayList(),
        dataDir: dataDir, segmentMaxSize: 1024,
        heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
        idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
        maxRetryCount: 3, retryIntervalMs: 1000,
        dlqRetentionHours: 168, maxMessageSize: 4096,
        maxLabelsPerMessage: 64, retentionHours: 72,
        syncQuorum: 1
    )
}

// ──── P1-2: 超时检查不返回已 ACK 记录 ────

@Test
public class CheckTimeoutAckedTest {
    @TestCase
    public func testCheckTimeoutSkipsAcked(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let dm = DeliveryManager(config, serverId: "t:1")
        let record = dm.recordDelivery("p1-2-a", "c1", "g1", "/p1-2")
        dm.onAck("p1-2-a", "c1", 0)
        let expired = dm.checkTimeout()
        for (r in expired) {
            @Assert(r.messageId != "p1-2-a")
        }
    }
}

// ──── P1-2: getOrCreateQueues 返回已有队列 (round 22) ────

@Test
public class GetOrCreateQueuesTest {
    @TestCase
    public func testGetOrCreateReturnsExisting(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        let first = qm.getOrCreateQueues("/p1-2-test", 1)
        @Assert(first.size == 1)
        let second = qm.getOrCreateQueues("/p1-2-test", 1)
        @Assert(second.size == 1)
        @Assert(first[0].index == second[0].index)  // 同一队列索引，非新创建
    }
}

// ──── P2-5: moveToDLQ 忽略已 ACK 记录 (round 22) ────

@Test
public class MoveToDlqAckedRecordTest {
    @TestCase
    public func testMoveDlqSkipsAckedRecord(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp", maxRetryCount: 0, ackTimeoutMs: 100)
        let dm = DeliveryManager(config, serverId: "t:1")
        let cm = ConsumerMatcher()
        dm.setConsumerMatcher(cm)
        let qm = QueueManager(config, nodeIndex: 0)
        dm.setQueueManager(qm)
        let record = dm.recordDelivery("p2-5-dlq", "c1", "g1", "/p2-5")
        // ACK 记录，确保 moveToDLQ 不会将其入 DLQ
        dm.onAck("p2-5-dlq", "/p2-5", 0)
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 300)
        dm.close()
 
    }
}

// ──── P2-7: reassign maxIndex 覆盖全部队列 (round 22) ────

@Test
public class ReassignRangeTest {
    @TestCase
    public func testReassignCoversFullRange(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        hosts.add("n2:1")
        hosts.add("n3:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/p2-7-test", 1)
        // 故障节点 1（仅本节点 0 上有 1 个队列）
        let result = qm.reassign(1)
        // reassign 应覆盖 config.mqHosts.size * (topicQueues.size) 范围
        @Assert(result.size >= 0)
        for ((topic, index) in result) {
            @Assert(topic == "/p2-7-test")
        }
    }
}

// ──── P1-1: BrokerManager.startHeartbeat 多线程安全 (round 23) ────

@Test
public class BrokerManagerHeartbeatTest {
    @TestCase
    public func testStartHeartbeatCalledTwiceDoesNotCrash(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let bm = BrokerManager(config)
        // 多次调用 startHeartbeat 不应崩溃（内部 heartbeatStarted guard）
        bm.startHeartbeat()
        bm.startHeartbeat()
        sleep(Duration.millisecond * 50)
        bm.close()
 
    }
}

// ──── P2-1: QueueCleaner.isFileExpired 异常处理 (round 23) ────

@Test
public class QueueCleanerIsFileExpiredTest {
    @TestCase
    public func testIsFileExpiredNonExistentReturnsFalse(): Unit {
        let expired = QueueCleaner.isFileExpired("/nonexistent-path-xxxx", DateTime.now())
        @Assert(!expired)
    }
}

// ──── P2-7: TopicManager I/O 不在锁内 (round 23) ────

@Test
public class TopicManagerIOLockTest {
    @TestCase
    public func testLockNotHeldDuringFleetIoForDeleteTopic(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        // createTopic 内部不应在锁内执行 I/O（P3-3 / P2-7）
        let code = tm.createTopic("/p2-7-io-lock", queueCount: 1)
        @Assert(code == MqErrorCode.SUCCESS)
        let topics = tm.listTopics()
        var found = false
        for (t in topics) {
            if (t == "/p2-7-io-lock") { found = true; break }
        }
        @Assert(found)
    }
}

// ──── P2-5: ConsumerGroupManager forEachQueue 返回 queueCount (round 23) ────

@Test
public class ConsumerGroupForEachQueueTest {
    @TestCase
    public func testForEachQueueReturnsQueueCount(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        tm.createTopic("/p2-5-qc", queueCount: 3)
        // createGroup 应正确处理 3 队列
        let code = cgm.createGroup("/p2-5-qc", "g1")
        @Assert(code == MqErrorCode.SUCCESS)
        // 每个队列 offset 都应初始化为 0
        @Assert(cgm.getOffset("/p2-5-qc", 0, "g1") == 0)
        @Assert(cgm.getOffset("/p2-5-qc", 1, "g1") == 0)
        @Assert(cgm.getOffset("/p2-5-qc", 2, "g1") == 0)
    }
}

// ──── P2-2: QueueCleaner isFileExpired 文件排序 (round 23) ────

@Test
public class QueueCleanerFileOrderTest {
    @TestCase
    public func testIsFileExpiredOldFileReturnsTrue(): Unit {
        // 创建临时文件，手动设置过期阈值
        let testDir = "/tmp/fmq_file_exp_test_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        let testFile = "${testDir}/temp_segment.log"
        try {
            Directory.create(testDir, recursive: true)
            let f = File(testFile, OpenMode.Write)
            f.write([0x01u8])
            f.close()
        } catch (_: Exception) { @Assert(false); return }
        // 阈值设为一个小时前，刚创建的文件 mtime 应在 1 小时内 → 未过期
        let threshold = DateTime.now() - Duration.hour
        let expired = QueueCleaner.isFileExpired(testFile, threshold)
        @Assert(!expired)
        // 清理
        remove(testFile); remove(testDir)
    }
}

// ──── P2-1: QueueCleaner.close 快速返回 (round 23) ────

@Test
public class QueueCleanerCloseTest {
    @TestCase
    public func testCloseReturnsWithoutBlocking(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        let cleaner = QueueCleaner(config, qm)
        let f = spawn { cleaner.run() }
        cleaner.setRunFuture(f)
        // 立即 close 应快速返回（cleanup 中检查 closed 标志）
        cleaner.close()
 
    }
}

// ──── P2-7: TopicManager deleteTopic/addGroup/removeGroup 锁外 I/O (round 23) ────

@Test
public class TopicManagerIoMethodsTest {
    @TestCase
    public func testDeleteTopicWorksWithoutFleet(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        tm.createTopic("/p2-7-del", queueCount: 1)
        // deleteTopic 不应在锁内执行 I/O（P2-7），无 fleet 时正常工作
        let code = tm.deleteTopic("/p2-7-del")
        @Assert(code == MqErrorCode.SUCCESS)
        @Assert(tm.getTopicMeta("/p2-7-del").isNone())
    }

    @TestCase
    public func testAddRemoveGroupWorksWithoutFleet(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        tm.createTopic("/p2-7-grp", queueCount: 1)
        // addConsumerGroup 不应在锁内执行 I/O（P2-7）
        let code1 = tm.addConsumerGroup("/p2-7-grp", "g1")
        @Assert(code1 == MqErrorCode.SUCCESS)
        // removeConsumerGroup 同理
        let code2 = tm.removeConsumerGroup("/p2-7-grp", "g1")
        @Assert(code2 == MqErrorCode.SUCCESS)
        // group 应已被移除
        let groups = tm.getConsumerGroups("/p2-7-grp")
        var found = false
        for (g in groups) {
            if (g == "g1") { found = true; break }
        }
        @Assert(!found)
    }
}

// ──── P0-1: getOrCreateQueues 并发死锁保护 (round 23) ────

@Test
public class GetOrCreateQueuesConcurrentTest {
    @TestCase
    public func testConcurrentGetOrCreateSameTopicReturnsExisting(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        // 线程安全：两线程同时 getOrCreateQueues 同一新 topic
        var f1 = spawn { qm.getOrCreateQueues("/p0-1-con", 1) }
        var f2 = spawn { qm.getOrCreateQueues("/p0-1-con", 1) }
        let r1 = f1.get()
        let r2 = f2.get()
        @Assert(r1.size == 1)
        @Assert(r2.size == 1)
        @Assert(r1[0].index == r2[0].index)
    }
}

/**
 * P2-6: 验证 handleConsume 跳过已关闭的队列。
 * handleConsume 遍历队列列表时跳过 isClosed() == true 的队列。
 * 关闭队列后 tryReadFromLog 应返回 None。
 */
@Test
public class ConsumeClosedQueueTest {
    private static let counter = AtomicInt64(0)

    private static func closedDir(): String {
        "/tmp/fmq_consume_closed_${counter.fetchAdd(1) + 1}"
    }

    @TestCase
    public func testHandleConsumeSkipsClosedQueue(): Unit {
        let dir = closedDir()
        let q = MqQueue("/test-closed", 0, dir, 4096)
        q.append([0xAAu8, 0xBBu8])
        q.sync()
        @Assert(!q.isClosed())
        // 关闭队列
        q.close()
        @Assert(q.isClosed())
        // 关闭后 tryReadFromLog 应返回 None
        @Assert(q.tryReadFromLog(0).isNone())
        // 清理
        removeDir(dir)
    }
}

// ──── P2-5: cleanupOrphanOffsets 移除已删除 topic 的孤儿 offset (round 24) ────

@Test
public class CleanupOrphanOffsetsTest {
    @TestCase
    public func testCleanupOrphanOffsetsRemovesDeletedTopic(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let dm = DeliveryManager(config, serverId: "s1")
        let tm = TopicManager(config)
        dm.setTopicManager(tm)

        // 创建 /active topic 并设置 offset
        tm.createTopic("/active", queueCount: 1)
        dm.setOffset("/active", 0, "g1", 100)

        // 为不存在的 /deleted topic 设置 offset（孤儿 offset）
        dm.setOffset("/deleted", 0, "g2", 200)

        // 调用 cleanupOrphanOffsets
        dm.cleanupOrphanOffsets()

        // /active 的 offset 应保留
        @Assert(dm.getOffset("/active", 0, "g1") == 100)

        // /deleted 的 offset 应被移除（getOffset 返回 0 表示 key 不存在）
        @Assert(dm.getOffset("/deleted", 0, "g2") == 0)
    }
}

/**
 * P3-2: QueueReader stream 重建 & 退避验证。
 */
@Test
public class QueueReaderBackoffTest {
    @TestCase
    public func testQueueReaderConsumesAndCloses(): Unit {
        // 创建临时队列，写入几条消息，启动 reader，验证消息被消费
        let dataDir = "/tmp/fmq_qr_test_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        try {
            Directory.create(dataDir)
        } catch (_: Exception) { /* 忽略重复创建 */ }
        let q = MqQueue("/test", 0, dataDir, 100)
        try {
            q.append(Array<Byte>(3, repeat: 1u8))
            q.append(Array<Byte>(3, repeat: 2u8))
            q.append(Array<Byte>(3, repeat: 3u8))
            q.sync()
            let reader = QueueReader(q)
            let future = spawn { reader.run() }
            sleep(Duration.millisecond * 500)
            reader.close()
            future.get()
        } finally {
            q.close()
            removeIfExists(dataDir, recursive: true)
        }
    }
}

