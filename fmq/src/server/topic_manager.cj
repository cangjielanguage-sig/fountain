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
 * 主题管理器。
 * 负责主题元数据在 fsync 中的 CRUD 操作。
 *
 * Phase 3 为骨架占位，fsync 集成将在后续阶段实现。
 */
public class TopicManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.TopicManager')

    public init(config: MqConfig) {
        this.config = config
    }

    /**
     * 创建主题（Phase 3 占位）。
     */
    public func createTopic(name: String, queueCount!: Int64 = 1): MqErrorCode {
        log.info("createTopic(${name}, queues=${queueCount}) - placeholder")
        MqErrorCode.SUCCESS
    }

    /**
     * 删除主题（Phase 3 占位）。
     */
    public func deleteTopic(name: String): MqErrorCode {
        log.info("deleteTopic(${name}) - placeholder")
        MqErrorCode.SUCCESS
    }

    /**
     * 列出所有主题（Phase 3 占位）。
     */
    public func listTopics(): ArrayList<String> {
        ArrayList()
    }

    /**
     * 获取主题元数据（Phase 3 占位）。
     */
    public func getTopicMeta(name: String): ?TopicMeta { None }
}
