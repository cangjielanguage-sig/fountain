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
 * 消费者组管理器。
 * 统一管理消费者组的创建/删除/查询，整合 TopicManager / ConsumerMatcher / DeliveryManager。
 */
public class ConsumerGroupManager {
    private let log = LoggerFactory.getLogger('fountain::fmq.ConsumerGroupManager')
    private let topicManager: TopicManager
    private let consumerMatcher: ConsumerMatcher
    private let deliveryManager: DeliveryManager

    public init(topicManager: TopicManager, consumerMatcher: ConsumerMatcher,
                deliveryManager: DeliveryManager) {
        this.topicManager = topicManager
        this.consumerMatcher = consumerMatcher
        this.deliveryManager = deliveryManager
    }

    /**
     * 遍历主题的所有队列执行操作（SRV-10: 消除 createGroup/deleteGroup 重复）。
     */
    private func forEachQueue(topic: String, block: (Int64) -> Unit): Int64 {
        let queueCount = if (let Some(meta) <- topicManager.getTopicMeta(topic)) {
            meta.getQueueCount()
        } else { 1 }
        for (i in 0..queueCount) {
            block(i)
        }
        queueCount
    }

    /**
     * 创建消费者组。
     * 1. 写入 TopicMeta.consumerGroups
     * 2. 初始化 offset = 0
     */
    public func createGroup(topic: String, groupId: String): MqErrorCode {
        let code = topicManager.addConsumerGroup(topic, groupId)
        if (code == MqErrorCode.SUCCESS) {
            let qc = forEachQueue(topic) { i => deliveryManager.setOffset(topic, i, groupId, 0) }
            log.info{"created consumer group '${groupId}' for topic '${topic}' with ${qc} queues"}
            MqErrorCode.SUCCESS
        } else if (code == MqErrorCode.GROUP_EXISTS) {
            log.info{"consumer group '${groupId}' already exists for topic '${topic}'"}
            MqErrorCode.SUCCESS
        } else {
            code
        }
    }

    /**
     * 删除消费者组。
     */
    public func deleteGroup(topic: String, groupId: String): MqErrorCode {
        topicManager.removeConsumerGroup(topic, groupId)
    }

    /**
     * 获取指定主题的所有消费者组。
     */
    public func getGroups(topic: String): ArrayList<String> {
        topicManager.getConsumerGroups(topic)
    }

    /**
     * 获取消费者组 offset。
     */
    public func getOffset(topic: String, queueIndex: Int64, groupId: String): Int64 {
        deliveryManager.getOffset(topic, queueIndex, groupId)
    }

    /**
     * 设置消费者组 offset。
     */
    public func setOffset(topic: String, queueIndex: Int64, groupId: String, offset: Int64): Unit {
        deliveryManager.setOffset(topic, queueIndex, groupId, offset)
    }

    /**
     * 注册消费者到组。
     * @param topic 所属主题（用于验证）
     * @param groupId 消费者组 ID
     * @param consumerId 消费者实例 ID
     * @param matchMode 匹配模式
     * @param labels 可选的标签过滤
     * @param dataFilter 可选的 DataPath 表达式过滤
     */
    public func registerConsumer(topic: String, groupId: String, consumerId: String,
                                  matchMode: MatchMode,
                                  labels!: ?ArrayList<String> = None,
                                  dataFilter!: ?String = None): Unit {
        let reg = ConsumerRegistration(
            consumerId: consumerId, groupId: groupId,
            matchModeStr: encodeMatchMode(matchMode),
            labels: labels, dataFilter: dataFilter,
            lastHeartbeat: DateTime.now())
        consumerMatcher.register(reg)
    }

    /**
     * 注销消费者。
     */
    public func deregisterConsumer(groupId: String, consumerId: String): Unit {
        consumerMatcher.deregister(groupId, consumerId)
    }

    /** 编码 MatchMode 为 ConsumerRegistration.matchModeStr 格式 */
    private static func encodeMatchMode(mode: MatchMode): String {
        match (mode) {
            case Exact(p) => "Exact:${p}"
            case Glob(p) => "Glob:${p}"
            case Prefix(p) => "Prefix:${p}"
        }
    }
}
