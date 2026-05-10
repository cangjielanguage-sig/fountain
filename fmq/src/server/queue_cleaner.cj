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

import std.fs.{File, OpenMode, remove}

/**
 * 消息过期清理后台线程。
 * 定期扫描已轮转的 SegmentedLog 文件，删除超过保留期的文件。
 * 每个队列至少保留最后 1 个文件。当前活跃文件不删。
 *
 * 清理间隔：每 5 分钟。
 * 保留策略：删除已轮转的旧文件，保留最后 1 个。
 * 未来可按 mq_retention_hours 基于文件 mtime 过滤。
 */
public class QueueCleaner {
    private let config: MqConfig
    private let queueManager: QueueManager
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueCleaner')
    private var closed: Bool = false

    public init(config: MqConfig, queueManager: QueueManager) {
        this.config = config
        this.queueManager = queueManager
    }

    public func close(): Unit { closed = true }

    /**
     * 后台线程主循环。
     */
    public func run(): Unit {
        log.info{"QueueCleaner started (interval=5min, retention=${config.retentionHours}h)"}
        while (!closed) {
            sleep(Duration.minute * 5)
            if (closed) { break }
            cleanup()
        }
    }

    /**
     * 单次清理：遍历所有队列，删除已轮转的旧文件（保留最后 1 个）。
     */
    public func cleanup(): Unit {
        var deletedCount: Int64 = 0
        for (topic in queueManager.listTopics()) {
            if (let Some(queues) <- queueManager.getQueues(topic)) {
                for (q in queues) {
                    if (q.isClosed()) { continue }
                    let oldFiles = q.log.takeOldFiles()
                    // 至少保留最后 1 个文件
                    if (oldFiles.size > 1) {
                        for (i in 0..oldFiles.size - 1) {
                            try {
                                remove(oldFiles[i])
                                deletedCount += 1
                            } catch (e: Exception) {
                                log.warn{"delete ${oldFiles[i]} failed: ${e.message}"}
                            }
                        }
                    }
                }
            }
        }
        if (deletedCount > 0) {
            let count = deletedCount
            log.info{"cleanup: deleted ${count} rotated segment files"}
        }
    }
}
