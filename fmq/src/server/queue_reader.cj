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

import std.sync.AtomicBool

/**
 * 队列读线程。
 * 从 SegmentedLog 流式读取消息，匹配消费者并投递。
 * 不缓冲，内存 O(1)。
 */
public class QueueReader {
    private let queue: MqQueue
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueReader')
    private let closed = AtomicBool(false)
    private var msgCount: Int64 = 0  // 已读取消息计数，用于首次读取时跳过历史消息

    public init(queue: MqQueue) {
        this.queue = queue
    }

    /**
     * 读线程主循环。
     * 1. 从 SegmentedLog 流式读取消息，首次读取时跳过已有偏移
     * 2. ConsumerMatcher.matchTopic() 获取投递目标
     * 3. 记录 DeliveryRecord（占位：后续集成实际网络投递）
     * 4. 等待 ACK 或超时
     *
     * TODO(P2-2): 当前实现仅读取数据并递增 msgCount，未执行消费者匹配/投递/ACK 跟踪。
     * 需要注入 ConsumerMatcher / DeliveryManager 引用，补充完整投递链路。
     * 当前状态：功能性死代码，读取的数据被丢弃。
     */
    public func run(): Unit {
        log.info{"QueueReader started for ${queue}"}
        while (!closed.load()) {
            try {
                let skip = msgCount
                if (let Some(data) <- queue.tryReadFromLog(skip)) {
                    msgCount += 1
                    log.debug{"read ${data.size} bytes from log for ${queue}"}
                    // TODO: 此处应调用 ConsumerMatcher.matchTopic() 匹配消费者并投递
                } else {
                    sleep(Duration.millisecond * 100)
                }
            } catch (e: Exception) {
                if (!closed.load()) {
                    log.error{"QueueReader error: ${e.message}"}
                }
            }
        }
    }

    public func close(): Unit { closed.store(true) }
}
