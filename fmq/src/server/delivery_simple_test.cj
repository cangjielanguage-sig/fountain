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
