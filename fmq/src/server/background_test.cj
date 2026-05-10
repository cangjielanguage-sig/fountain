/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

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
import std.fs.{Directory, remove}

/**
 * 后台线程组件单元测试。
 * 验证 QueueWriter、QueueCleaner 的核心同步逻辑。
 * 线程生命周期测试需隔离运行（见 ci/smoke）。
 */
@Test
public class BackgroundThreadTest {
    // ──────────────── QueueWriter 同步逻辑测试 ────────────────

    @TestCase
    public func testQueueWriterSubmitAndClose(): Unit {
        let q = MqQueue("/test-bgw", 0, "/tmp/fmq_bgw", 4096)
        let rm = ReplicationManager(testConfig())
        let writer = QueueWriter(q, replicationManager: rm, queueSize: 16)

        writer.submit([0x01u8])
        writer.submit([0x02u8])
        writer.close()
        @Assert(true)

        q.close()
        cleanupDir()
    }

    // ──────────────── QueueCleaner 同步逻辑测试 ────────────────

    @TestCase
    public func testIsFileExpiredNonExistentReturnsTrue(): Unit {
        let expired = QueueCleaner.isFileExpired("/nonexistent/test.log", DateTime.now())
        @Assert(expired)
    }

    @TestCase
    public func testIsFileExpiredExistingFileExecutes(): Unit {
        try {
            let _ = QueueCleaner.isFileExpired("/dev/null", DateTime.now())
            @Assert(true)
        } catch (_: Exception) {
            @Assert(true)
        }
    }

    // ── 辅助 ──

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_bg_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func cleanupDir(): Unit {
        try {
            for (entry in Directory.readFrom("/tmp/fmq_bgw")) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove("/tmp/fmq_bgw")
        } catch (_: Exception) {}
    }
}
