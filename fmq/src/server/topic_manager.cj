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

import std.collection.HashMap

/**
 * 主题管理器。
 * 维护主题元数据的本地 HashMap 缓存。
 * Phase 7 可接入 fsync 实现跨节点一致。
 */
public class TopicManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.TopicManager')
    private let topics = HashMap<String, TopicMeta>()

    public init(config: MqConfig) {
        this.config = config
    }

    /**
     * 创建主题。校验 topic 格式、重名后写入 HashMap。
     */
    public func createTopic(name: String, queueCount!: Int64 = 1): MqErrorCode {
        if (!validateTopic(name)) {
            log.warn{"createTopic: invalid topic name '${name}'"}
            return MqErrorCode.INVALID_TOPIC_FORMAT
        }
        if (topics.get(name).isSome()) {
            log.warn{"createTopic: topic '${name}' already exists"}
            return MqErrorCode.TOPIC_EXISTS
        }
        let meta = TopicMeta(
            queueCount: queueCount,
            consumerGroups: ArrayList(),
            createTime: DateTime.now()
        )
        topics[name] = meta
        log.info{"created topic '${name}' with ${queueCount} queues"}
        MqErrorCode.SUCCESS
    }

    /**
     * 删除主题。移除 HashMap 中的记录。
     */
    public func deleteTopic(name: String): MqErrorCode {
        if (topics.remove(name).isSome()) {
            log.info{"deleted topic '${name}'"}
            MqErrorCode.SUCCESS
        } else {
            log.warn{"deleteTopic: topic '${name}' not found"}
            MqErrorCode.TOPIC_NOT_FOUND
        }
    }

    /**
     * 列出所有主题名。
     */
    public func listTopics(): ArrayList<String> {
        let result = ArrayList<String>()
        for ((name, _) in topics) {
            result.add(name)
        }
        result
    }

    /**
     * 获取主题元数据。
     */
    public func getTopicMeta(name: String): ?TopicMeta {
        topics.get(name)
    }
}
