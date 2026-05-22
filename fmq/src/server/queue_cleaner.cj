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

import std.fs.{File, OpenMode, remove, FileInfo}
import std.sync.AtomicBool

/**
 * 消息过期清理后台线程。
 * 定期扫描已轮转的 SegmentedLog 文件，删除超过保留期的文件。
 * 每个队列至少保留最后 1 个文件。当前活跃文件不删。
 *
 * 清理间隔：每 5 分钟。
 * 保留策略：按 config.retentionHours 基于文件 mtime 过滤，
 * 至少保留 1 个已轮转文件防止重复创建。
 */
public class QueueCleaner {
    private let config: MqConfig
    private let queueManager: QueueManager
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueCleaner')
    private let closed = AtomicBool(false)
    private var topicCursor: Int64 = 0
    private var queueCursor: Int64 = 0

    public init(config: MqConfig, queueManager: QueueManager) {
        this.config = config
        this.queueManager = queueManager
    }

    public func close(): Unit {
        closed.store(true)
    }

    /**
     * 后台线程主循环。
     */
    public func run(): Unit {
        log.info{"QueueCleaner started (interval=5min, retention=${config.retentionHours}h)"}
        while (!closed.load()) {
            sleep(Duration.minute * 5)
            try {
                cleanup()
            } catch (e: Exception) {
                log.error{"QueueCleaner.run cleanup failed: ${e.message}"}
            }
        }
    }

    /**
     * 单次清理：遍历所有队列，删除超过保留期的已轮转文件（保留最后 1 个）。
     * 为减少单次清理对正常业务的干扰，支持按 batchSize 分批执行，
     * 本周期未完成的队列由下一周期继续。
     * retentionHours=0 时跳过所有文件（不清理）。
     *
     * 性能：每 5 分钟执行一次，分批处理分散负载。
     */
    public func cleanup(): Unit {
        let retentionThreshold = if (config.retentionHours > 0) {
            DateTime.now() - Duration.hour * config.retentionHours
        } else {
            // retentionHours=0 无限保留
            return
        }
        var deletedCount: Int64 = 0
        var processed: Int64 = 0
        let batchSize = config.cleanupBatchSize
        let topics = queueManager.listTopics()
        var ti = topicCursor

        while (ti < topics.size) {
            let topic = topics[ti]
            if (let Some(queues) <- queueManager.getQueues(topic)) {
                var qi = if (ti == topicCursor) { queueCursor } else { 0 }
                while (qi < queues.size) {
                    if (batchSize > 0 && processed >= batchSize) {
                        // 达到批次上限，保存游标并返回
                        topicCursor = ti
                        queueCursor = qi
                        if (deletedCount > 0) {
                            let count = deletedCount
                            log.info{"cleanup: deleted ${count} files (partial)"}
                        }
                        return
                    }
                    let q = queues[qi]
                    if (!q.isClosed()) {
                        let oldFiles: ArrayList<String>
                        try {
                            oldFiles = q.log.takeOldFiles()
                        } catch (e: Exception) {
                            log.warn{"takeOldFiles ${q} failed: ${e.message}"}
                            qi += 1
                            processed += 1
                            continue
                        }
                        var remaining = 1  // 至少保留最后 1 个文件
                        for (f in oldFiles) {
                            if (remaining > 0) {
                                remaining -= 1
                                continue
                            }
                            try {
                                if (isFileExpired(f, retentionThreshold)) {
                                    remove(f)
                                    deletedCount += 1
                                }
                            } catch (e: Exception) {
                                log.warn{"check/delete ${f} failed: ${e.message}"}
                            }
                        }
                    }
                    qi += 1
                    processed += 1
                }
            }
            ti += 1
        }

        // 全部遍历完成，重置游标
        topicCursor = 0
        queueCursor = 0
        if (deletedCount > 0) {
            let count = deletedCount
            log.info{"cleanup: deleted ${count} expired segment files"}
        }
    }

    /**
     * 检查文件是否超过保留期。
     * 文件不存在返回 false（无物可删），权限错误日志告警并返回 false。
     */
    internal static func isFileExpired(path: String, threshold: DateTime): Bool {
        try {
            let info = FileInfo(path)
            info.lastModificationTime < threshold
        } catch (_: Exception) { false }
    }
}
