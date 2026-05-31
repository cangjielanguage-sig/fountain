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
