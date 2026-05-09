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
 * 从 Queue.deliveryBuffer（Writer→Reader 管道）读取消息，匹配消费者并投递。
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
     * 1. 从 deliveryBuffer 获取下一条消息
     * 2. ConsumerMatcher.matchTopic() 获取投递目标
     * 3. 记录 DeliveryRecord（占位：后续集成实际网络投递）
     * 4. 等待 ACK 或超时
     */
    public func run(): Unit {
        log.info{"QueueReader started for ${queue}"}
        while (!closed) {
            try {
                // 1. 取消息（阻塞直到有数据或 close）
                let data = queue.deliveryBuffer.remove()
                if (closed) { break }

                // 2. ConsumerMatcher.matchTopic 获取目标消费者
                //    （主节点上下文中 consumerMatcher 是已知的，这里为占位代码）
                log.debug{"delivery buffer got ${data.size} bytes for ${queue}"}

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
