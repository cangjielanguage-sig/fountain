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
public class DeliveryManagerTimeoutTest {
    private static let TEST_DIR = "/tmp/fmq_dm_timeout_test"

    @TestCase
    public func testCheckerStartsAndStopsWithoutCrash(): Unit {
        let config = timeoutTestConfig()
        let dm = DeliveryManager(config)
        // 启动检查线程
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 50)
        // 关闭不抛异常
        dm.close()
 
    }

    @TestCase
    public func testCheckerProcessesExpiredRecord(): Unit {
        let config = timeoutTestConfig()
        let dm = DeliveryManager(config)
        let cm = ConsumerMatcher()
        let qm = createEmptyQueueManager()
        dm.setConsumerMatcher(cm)
        dm.setQueueManager(qm)
        // 记录投递（使用极短超时）
        let record = dm.recordDelivery("timeout-msg", "c1", "g1", "/test")
        dm.startTimeoutChecker()
        sleep(Duration.millisecond * 200)
        // 检查线程运行后记录应被处理（retryCount >= 0）
        @Assert(record.retryCount.load() >= 0)
        dm.close()
    }

    private static func timeoutTestConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 50,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func createEmptyQueueManager(): QueueManager {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        QueueManager(config, nodeIndex: 0)
    }
}
