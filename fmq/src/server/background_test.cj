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
 *
 * 线程生命周期（spawn → run() → close 停止）需要 SegmentedLog，
 * 在 WSL 上 mmap init ~110ms，全量套件中超时。
 * 隔离运行：cjpm test --filter BackgroundThreadLifecycleTest
 */
@Test
public class BackgroundThreadTest {
    private static let TEST_DIR = "/tmp/fmq_bg_test"

    @TestCase
    public func testQueueWriterSubmitAndClose(): Unit {
        let q = createQueue("w-sc")
        let rm = ReplicationManager(testConfig())
        let writer = QueueWriter(q, replicationManager: rm, queueSize: 16)

        writer.submit([0x01u8])
        writer.submit([0x02u8])

        // 启动 writer 线程处理提交，然后关闭
        let future = spawn { writer.run() }
        sleep(Duration.millisecond * 100)
        writer.close()
        future.get()

        // 验证写入的数据可从队列读取
        @Assert(q.tryReadFromLog(0).isSome())
        q.close()
        cleanupTopic("w-sc")
    }

    @TestCase
    public func testIsFileExpiredNonExistentReturnsTrue(): Unit {
        @Assert(QueueCleaner.isFileExpired("/nonexistent/test.log", DateTime.now()))
    }

    @TestCase
    public func testIsFileExpiredExistingFileExecutes(): Unit {
        // /dev/null mtime 应远小于当前时间，isFileExpired 应返回 true（已过期）
        let now = DateTime.now()
        @Assert(QueueCleaner.isFileExpired("/dev/null", now))
    }

    /**
     * cleanup() 空管理器不崩溃——验证 takeOldFiles try-catch。
     */
    @TestCase
    public func testCleanupWithEmptyQueues(): Unit {
        let config = testConfig()
        let qm = QueueManager(config, nodeIndex: 0)
        let cleaner = QueueCleaner(config, qm)
        cleaner.cleanup()  // 无队列 → return，不抛异常
        @Assert(true)
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func createQueue(name: String): MqQueue {
        MqQueue("/${name}", 0, TEST_DIR, 16384)
    }

    private static func cleanupTopic(name: String): Unit {
        let path = "${TEST_DIR}/${name}/0"
        try {
            for (entry in Directory.readFrom(path)) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove(path)
        } catch (_: Exception) {}
    }
}

/**
 * QueueWriter/QueueReader 线程生命周期测试（需隔离运行）。
 * 单独运行：cjpm test --filter BackgroundThreadLifecycleTest
 *
 * 这些测试需要创建 SegmentedLog 并启动后台线程，
 * 在全量测试套件中可能因文件系统竞争超时。
 */
@Test
public class BackgroundThreadLifecycleTest {
    private static let TEST_DIR = "/tmp/fmq_bg_lifecycle"

    @TestCase
    public func testQueueWriterRunClosesOnFlag(): Unit {
        let q = createQueue("wr-flag")
        let rm = ReplicationManager(testConfig())
        let writer = QueueWriter(q, replicationManager: rm, queueSize: 16)

        writer.submit([0x10u8])

        let future = spawn { writer.run() }
        sleep(Duration.millisecond * 100)
        writer.close()
        future.get()

        @Assert(q.tryReadFromLog(0).isSome())
        q.close()
        clearTopic("wr-flag")
    }

    @TestCase
    public func testQueueWriterCloseStopsIdleRun(): Unit {
        let q = createQueue("wr-idle")
        let rm = ReplicationManager(testConfig())
        let writer = QueueWriter(q, replicationManager: rm, queueSize: 16)

        let future = spawn { writer.run() }
        sleep(Duration.millisecond * 100)
        writer.close()
        future.get()
        @Assert(!q.isClosed())

        q.close()
        clearTopic("wr-idle")
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: TEST_DIR, segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func createQueue(name: String): MqQueue {
        MqQueue("/${name}", 0, TEST_DIR, 16384)
    }

    private static func clearTopic(name: String): Unit {
        let path = "${TEST_DIR}/${name}/0"
        try {
            for (entry in Directory.readFrom(path)) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove(path)
        } catch (_: Exception) {}
    }
}
