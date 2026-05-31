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
