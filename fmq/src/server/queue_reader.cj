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
 * 从 SegmentedLog 流式读取消息，匹配消费者并投递。
 * 不缓冲，内存 O(1)。
 */
public class QueueReader {
    private let queue: Queue
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueReader')
    private var closed: Bool = false

    public init(queue: Queue) {
        this.queue = queue
    }

    /**
     * 读线程主循环。
     * 1. 从 SegmentedLog 逐条读取消息
     * 2. ConsumerMatcher.matchTopic() 获取投递目标
     * 3. 记录 DeliveryRecord（占位：后续集成实际网络投递）
     * 4. 等待 ACK 或超时
     */
    public func run(): Unit {
        log.info{"QueueReader started for ${queue}"}
        while (!closed) {
            try {
                // 1. 从 SegmentedLog 流式读取（O(1) 内存）
                if (let Some(data) <- queue.tryReadFromLog(0)) {
                    // 2. ConsumerMatcher.matchTopic 获取目标消费者（占位）
                    log.debug{"read ${data.size} bytes from log for ${queue}"}
                } else {
                    // 无消息时短暂等待
                    sleep(Duration.millisecond * 100)
                }
                // 3. 超时检查（Phase 4+ 实现在 DeliveryManager.checkTimeout）
            } catch (e: Exception) {
                if (!closed) {
                    log.error{"QueueReader error: ${e.message}"}
                }
            }
        }
    }

    public func close(): Unit { closed = true }
}
