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
import std.io.ByteBuffer
import fountain::f_codec.default.DefaultCodec

/**
 * 后台线程组件单元测试。
 * 验证 QueueWriter、QueueCleaner 的核心同步逻辑。
 *
 * 线程生命周期（spawn → run() → close 停止）需要 SegmentedLog，
 * 在 WSL 上 mmap init ~110ms，全量套件中超时。
 * 隔离运行：cjpm test --filter BackgroundThreadLifecycleTest
 */

@Test
public class QueueCleanerFutureTest {
    @TestCase
    public func testCloseSetsFlagDoesNotBlock(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_qc_future", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let qm = QueueManager(config, nodeIndex: 0)
        let cleaner = QueueCleaner(config, qm)
        // 在没有 run 线程的情况下 close() 不应抛异常
        cleaner.close()
 
    }

    @TestCase
    public func testCleanerRunCloseReturnsQuickly(): Unit {
        // 验证 run() 使用 100ms 短间隔轮询后，close() 中的 join 可快速返回。
        // 旧实现 sleep(5min) 会导致 close() 阻塞 5 分钟。
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_qc_runclose", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let qm = QueueManager(config, nodeIndex: 0)
        let cleaner = QueueCleaner(config, qm)
        let f = spawn { cleaner.run() }
        cleaner.setRunFuture(f)
        sleep(Duration.millisecond * 50)  // 让 run 循环启动
        // close() 应快速返回（100ms 内），不会阻塞 5 分钟
        let start = DateTime.now()
        cleaner.close()
        f.get()
        let elapsed = DateTime.now() - start
        @Assert(elapsed < Duration.second)  // 关闭应在 1 秒内完成
    }
}
