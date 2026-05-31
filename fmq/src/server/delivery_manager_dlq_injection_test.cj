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
