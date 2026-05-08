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

/**
 * 队列读线程。
 * 从 SegmentedLog 文件读取消息，匹配消费者，投递。
 *
 * Phase 3 为骨架占位，完整的 ConsumerMatcher 集成在 Phase 4 实现。
 * 读操作用 pread 打开 SegmentedLog 的 segment 文件直接读取。
 */
public class QueueReader {
    private let queue: Queue
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueReader')
    private var closed: Bool = false

    public init(queue: Queue) {
        this.queue = queue
    }

    /**
     * 读线程主循环（Phase 3 占位）。
     */
    public func run(): Unit {
        log.info("QueueReader started for ${queue}")
        while (!closed) {
            try {
                // Phase 4: 读取消息 → ConsumerMatcher.match() → 投递 → ACK/重试
                sleep(Duration.millisecond * 100)
            } catch (e: Exception) {
                log.error("QueueReader error: ${e.message}")
            }
        }
    }

    public func close(): Unit { closed = true }
}
