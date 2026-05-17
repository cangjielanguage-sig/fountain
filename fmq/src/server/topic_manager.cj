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
import std.sync.Mutex
import fountain::f_codec.default.DefaultCodec
import std.io.ByteBuffer
import fountain::fleet.client.SyncClient

/**
 * 主题管理器。
 * 维护主题元数据的本地缓存 + fleet 持久化。
 * 启动时从 fleet 恢复主题列表，运行时同步写入 fleet。
 */
public class TopicManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.TopicManager')
    private let topics = HashMap<String, TopicMeta>()
    private let syncClient: ?SyncClient
    private let lock = Mutex()  // 保护 topics HashMap 并发访问

    public init(config: MqConfig) {
        this.config = config
        this.syncClient = tryCreateSyncClient()
    }

    /**
     * 从 fleet 恢复所有主题。
     * 启动时调用。
     */
    public func restore(): Unit {
        if (let Some(fleet) <- syncClient) {
            try {
                let result = fleet.prefix("/mq/topics/")
                for (i in 0..result.size) {
                    if (let Some(key) <- result.getKey(i)
                        && let Some(bytes) <- result.getValue(i)) {
                        let name = key[11..]  // 去掉 "/mq/topics/"
                        if (let Some(meta) <- DefaultCodec().decode<TopicMeta>(ByteBuffer(bytes))) {
                            topics[name] = meta
                            log.info{"restored topic '${name}' from fleet"}
                        }
                    }
                }
                log.info{"restore: loaded ${topics.size} topics from fleet"}
            } catch (e: Exception) {
                log.warn{"restore from fleet failed: ${e.message}"}
            }
        }
    }

    public func createTopic(name: String, queueCount!: Int64 = 1): MqErrorCode {
        synchronized(lock) {
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
            persistToFsync(name, meta)
        }
        log.info{"created topic '${name}' with ${queueCount} queues"}
        MqErrorCode.SUCCESS
    }

    public func deleteTopic(name: String): MqErrorCode {
        synchronized(lock) {
            if (topics.remove(name).isSome()) {
                deleteFromFsync(name)
                log.info{"deleted topic '${name}'"}
                MqErrorCode.SUCCESS
            } else {
                log.warn{"deleteTopic: topic '${name}' not found"}
                MqErrorCode.TOPIC_NOT_FOUND
            }
        }
    }

    public func listTopics(): ArrayList<String> {
        let result = ArrayList<String>()
        for ((name, _) in topics) {
            result.add(name)
        }
        result
    }

    public func getTopicMeta(name: String): ?TopicMeta {
        topics.get(name)
    }

    public func addConsumerGroup(topic: String, group: String): MqErrorCode {
        synchronized(lock) {
            if (let Some(meta) <- topics.get(topic)) {
                let groups = ArrayList<String>()
                for (g in meta.getConsumerGroups()) {
                    if (g == group) { return MqErrorCode.GROUP_EXISTS }
                    groups.add(g)
                }
                groups.add(group)
                let newMeta = TopicMeta(
                    queueCount: meta.getQueueCount(),
                    consumerGroups: groups,
                    createTime: meta.getCreateTime()
                )
                topics[topic] = newMeta
                persistToFsync(topic, newMeta)
                log.info{"added group '${group}' to topic '${topic}'"}
                MqErrorCode.SUCCESS
            } else {
                MqErrorCode.TOPIC_NOT_FOUND
            }
        }
    }

    public func removeConsumerGroup(topic: String, group: String): MqErrorCode {
        synchronized(lock) {
            if (let Some(meta) <- topics.get(topic)) {
                let groups = ArrayList<String>()
                var found = false
                for (g in meta.getConsumerGroups()) {
                    if (g == group) { found = true }
                    else { groups.add(g) }
                }
                if (!found) { return MqErrorCode.GROUP_NOT_FOUND }
                let newMeta = TopicMeta(
                    queueCount: meta.getQueueCount(),
                    consumerGroups: groups,
                    createTime: meta.getCreateTime()
                )
                topics[topic] = newMeta
                persistToFsync(topic, newMeta)
                log.info{"removed group '${group}' from topic '${topic}'"}
                MqErrorCode.SUCCESS
            } else {
                MqErrorCode.TOPIC_NOT_FOUND
            }
        }
    }

    public func getConsumerGroups(topic: String): ArrayList<String> {
        if (let Some(meta) <- topics.get(topic)) {
            let result = ArrayList<String>()
            for (g in meta.getConsumerGroups()) {
                result.add(g)
            }
            result
        } else {
            ArrayList()
        }
    }

    /**
     * 列出所有 topic → consumerGroups 映射（批量查询，单次锁内完成）。
     */
    public func listAllConsumerGroups(): HashMap<String, ArrayList<String>> {
        let result = HashMap<String, ArrayList<String>>()
        for ((name, meta) in topics) {
            let groups = ArrayList<String>()
            for (g in meta.getConsumerGroups()) {
                groups.add(g)
            }
            if (groups.size > 0) {
                result[name] = groups
            }
        }
        result
    }

    // ───── fleet 持久化 ─────

    private func persistToFsync(name: String, meta: TopicMeta): Unit {
        if (let Some(fleet) <- syncClient) {
            try {
                fleet.add<TopicMeta>("/mq/topics/" + name, meta)
            } catch (e: Exception) {
                log.warn{"persist topic '${name}' to fleet failed: ${e.message}"}
            }
        }
    }

    private func deleteFromFsync(name: String): Unit {
        if (let Some(fleet) <- syncClient) {
            try {
                fleet.delete("/mq/topics/" + name)
            } catch (e: Exception) {
                log.warn{"delete topic '${name}' from fleet failed: ${e.message}"}
            }
        }
    }

    private static func tryCreateSyncClient(): ?SyncClient {
        try { SyncClient.getInstance() } catch (_: Exception) { None }
    }
}
