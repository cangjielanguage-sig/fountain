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
