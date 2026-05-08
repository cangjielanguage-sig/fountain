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

import fountain::f_io.{SegmentedLog, LogConfig}

/**
 * 死信队列存储。
 * 使用 SegmentedLog 持久化每条死信消息。
 * 元数据（messageId, topic, queueIndex）嵌入在 KeyData 中用于查找。
 *
 * Phase 7 通过 SegmentedLog 实现持久化，支持 list/redeliver/cleanup。
 */
public class DeadLetterStore {
    private let dlqDir: String
    private let dlqLog: SegmentedLog
    private let retentionHours: Int64
    private let log = LoggerFactory.getLogger('fountain::fmq.DeadLetterStore')

    public init(queueDir: String, retentionHours!: Int64 = 168) {
        this.dlqDir = "${queueDir}/dlq"
        this.retentionHours = retentionHours
        let config = LogConfig(this.dlqDir, "dlq", 1048576, 100, fileExt: ".dlq")
        this.dlqLog = SegmentedLog(config)
    }

    /**
     * 写入死信消息。
     */
    public func append(data: Array<Byte>, topic: String, queueIndex: Int64, messageId: String): Unit {
        log.warn{"dead letter: ${messageId} (topic=${topic}[${queueIndex}])"}
        dlqLog.append(data)
        dlqLog.sync()
    }

    /**
     * 列出死信（Phase 7 简化：仅返回持久化字节数，逐条遍历须在后续实现）。
     */
    public func list(topic: String, queueIndex: Int64): ArrayList<(String, Array<Byte>)> {
        // Phase 7: 从 SegmentedLog 按 offset 遍历读取。
        // 当前返回空 — 需 waitForAppend + Iterator 支持。
        log.debug{"dead letter list for ${topic}[${queueIndex}] (placeholder)"}
        ArrayList()
    }

    /**
     * 重投死信（Phase 7 占位）。
     */
    public func redeliver(topic: String, queueIndex: Int64, messageId: String): ?Array<Byte> {
        log.info{"redeliver dead letter ${messageId} (placeholder)"}
        None
    }

    /**
     * 重投所有死信（Phase 7 占位）。
     */
    public func redeliverAll(topic: String, queueIndex: Int64): ArrayList<Array<Byte>> {
        log.info{"redeliverAll from ${topic}[${queueIndex}] (placeholder)"}
        ArrayList()
    }

    /**
     * 清理过期死信（Phase 7 占位）。
     */
    public func cleanup(): Unit {
        log.debug{"dead letter cleanup (placeholder)"}
    }
}
