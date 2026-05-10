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

    public init(config: MqConfig, queueManager: QueueManager) {
        this.config = config
        this.queueManager = queueManager
    }

    public func close(): Unit { closed.store(true) }

    /**
     * 后台线程主循环。
     */
    public func run(): Unit {
        log.info{"QueueCleaner started (interval=5min, retention=${config.retentionHours}h)"}
        while (!closed.load()) {
            sleep(Duration.minute * 5)
            if (closed.load()) { break }
            cleanup()
        }
    }

    /**
     * 单次清理：遍历所有队列，删除超过保留期的已轮转文件（保留最后 1 个）。
     * retentionHours=0 时跳过所有文件（不清理）。
     */
    public func cleanup(): Unit {
        let retentionThreshold = if (config.retentionHours > 0) {
            DateTime.now() - Duration.hour * config.retentionHours
        } else {
            // retentionHours=0 无限保留
            return
        }
        var deletedCount: Int64 = 0
        for (topic in queueManager.listTopics()) {
            if (let Some(queues) <- queueManager.getQueues(topic)) {
                for (q in queues) {
                    if (q.isClosed()) { continue }
                    let oldFiles = q.log.takeOldFiles()
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
            }
        }
        if (deletedCount > 0) {
            let count = deletedCount
            log.info{"cleanup: deleted ${count} expired segment files"}
        }
    }

    /**
     * 检查文件是否超过保留期。
     * metadata() 不存在的文件视为过期（可删除）。
     */
    private static func isFileExpired(path: String, threshold: DateTime): Bool {
        try {
            let info = FileInfo(path)
            info.lastModificationTime < threshold
        } catch (_: Exception) { true }
    }
}
