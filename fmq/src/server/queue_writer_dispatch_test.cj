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
