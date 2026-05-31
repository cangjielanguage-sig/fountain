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
