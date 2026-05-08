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
 * 死信队列存储。
 * 管理死信消息的写入、读取和清理。
 *
 * Phase 3 为骨架占位，SegmentedLog 集成在后续阶段实现。
 */
public class DeadLetterStore {
    private let dlqDir: String
    private let log = LoggerFactory.getLogger('fountain::fmq.DeadLetterStore')

    public init(queueDir: String) {
        this.dlqDir = "${queueDir}/dlq"
    }

    /**
     * 写入死信消息（Phase 3 占位）。
     */
    public func append(data: Array<Byte>): Unit {
        // Phase 3: 暂不持久化，仅打日志
        log.warn("dead letter entry (not yet persisted), size=${data.size}")
    }

    /**
     * 列出死信消息（Phase 3 占位）。
     */
    public func list(): ArrayList<Array<Byte>> { ArrayList() }

    /**
     * 重新投递死信消息（Phase 3 占位）。
     */
    public func redeliver(data: Array<Byte>): Unit {
        log.info("redeliver dead letter (placeholder)")
    }
}
