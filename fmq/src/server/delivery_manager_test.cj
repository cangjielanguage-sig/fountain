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
