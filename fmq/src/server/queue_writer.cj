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

import std.collection.concurrent.ConcurrentLinkedQueue

/**
 * 队列写线程。
 * 接收生产者发来的消息，写入 SegmentedLog，响应结果。
 *
 * Phase 3 为骨架占位，完整的协议集成将在 Phase 6 实现。
 */
public class QueueWriter {
    private let queue: Queue
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueWriter')
    private var closed: Bool = false
    private let inboundQueue: ConcurrentLinkedQueue<Array<Byte>>

    public init(queue: Queue, queueSize!: Int64 = 1024) {
        this.queue = queue
        this.inboundQueue = ConcurrentLinkedQueue<Array<Byte>>()
    }

    /**
     * 提交数据到写入队列。
     */
    public func submit(data: Array<Byte>): Unit {
        inboundQueue.add(data)
    }

    /**
     * 写线程主循环。
     */
    public func run(): Unit {
        while (!closed) {
            try {
                if (let Some(data) <- inboundQueue.remove()) {
                    queue.append(data)
                } else {
                    sleep(Duration.millisecond * 10)
                }
            } catch (e: Exception) {
                log.error("QueueWriter error: ${e.message}")
            }
        }
    }

    public func close(): Unit { closed = true }
}
