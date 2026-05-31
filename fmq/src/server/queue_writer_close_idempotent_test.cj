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
