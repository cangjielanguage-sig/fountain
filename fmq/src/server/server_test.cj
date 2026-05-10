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
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.base.*
import std.io.{InputStream, SeekPosition}

@Test
public class QueueDistributionTest {
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
            @Assert(q.draining)
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

@Test
public class DeliverySimpleTest {
    @TestCase
    public func testRecordAndAck(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        let record = dm.recordDelivery("msg1", "consumer1", "group1")
        @Assert(record.messageId == "msg1")
        let ok = dm.onAck("msg1", "/test", 0)
        @Assert(ok)
    }

    @TestCase
    public func testDoubleAckReturnsFalse(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        dm.recordDelivery("msg1", "consumer1", "group1")
        dm.onAck("msg1", "/test", 0)
        let second = dm.onAck("msg1", "/test", 0)
        @Assert(!second)
    }

    @TestCase
    public func testConcurrentAckSingleSuccess(): Unit {
        let config = deliveryTestConfig()
        let dm = DeliveryManager(config)
        dm.recordDelivery("concurrent-msg", "consumer-c", "group-c")

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
public class DeadLetterStoreTest {
    @TestCase
    public func testAppendAndList(): Unit {
        let ds = DeadLetterStore("/tmp/fmq_dlq_test", retentionHours: 168)
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
        let ds = DeadLetterStore("/tmp/fmq_dlq_test2", retentionHours: 168)
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
        let ds = DeadLetterStore("/tmp/fmq_dlq_test3", retentionHours: 168)
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
        let ds = DeadLetterStore("/tmp/fmq_dlq_rebuild", retentionHours: 168)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.append([0x02u8], "/b", 0, "msg-2")
        // redeliver 会从索引删除
        ds.redeliver("/a", 0, "msg-1")
        @Assert(ds.list("/a", 0).size == 0)
        @Assert(ds.list("/b", 0).size == 1)
    }
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

