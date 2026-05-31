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
    // P3-2: 跟踪 stream 状态以避免每次 poll 都重建 stream 并重新解码 skip 条记录
    private var streamActive = false
    private var exhaustedCount: Int64 = 0
    private var consecutiveZeroB: Int64 = 0  // 连续 0B entry，检测 mmap tail

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
                // P3-2: streamActive 时 skip=0（复用缓存 stream），避免 O(msgCount) 重建
                let skip = if (streamActive) { 0 } else { msgCount }
                if (let Some(data) <- queue.tryReadFromLog(skip)) {
                    if (data.size == 0) {
                        // mmap tail: DefaultCodec 将零填充区解码为 0 字节数组
                        consecutiveZeroB += 1
                        if (consecutiveZeroB >= 3) {
                            consecutiveZeroB = 0
                            msgCount += 1  // 推进位置
                        }
                        streamActive = false  // 强制进入退避
                    } else {
                        consecutiveZeroB = 0
                        streamActive = true
                        exhaustedCount = 0
                        msgCount += 1
                        log.debug{"read ${data.size} bytes from log for ${queue}"}
                    }
                }
                if (!streamActive) {
                    consecutiveZeroB = 0
                    exhaustedCount += 1
                    // P3-2: 指数退避减少 O(msgCount) stream 重建频率
                    // 分段 sleep（每 100ms 检查 closed），确保 close() 可及时唤醒
                    let shift = if (exhaustedCount > 4) { 4 } else { exhaustedCount }
                    let totalWaitMs = 100i64 << shift
                    var waitedMs: Int64 = 0
                    while (waitedMs < totalWaitMs && !closed.load()) {
                        sleep(Duration.millisecond * 100)
                        waitedMs += 100
                    }
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
