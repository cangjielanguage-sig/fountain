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
package fountain::fmq.common

import fountain::f_data.macros.*

/**
 * 主题元数据，存储在 fleet /mq/topic/<topic>。
 */
@DataAssist[props fields]
public class TopicMeta {
    private var queueCount: Int64 = 1
    private var consumerGroups: ArrayList<String> = ArrayList()
    private var createTime: DateTime = DateTime.now()
    public init() {}

    public init(queueCount!: Int64, consumerGroups!: ArrayList<String>, createTime!: DateTime) {
        this.queueCount = queueCount
        this.consumerGroups = consumerGroups
        this.createTime = createTime
    }

    // 字段访问器（private var 需公开 getter）
    public func getQueueCount(): Int64 { queueCount }
    public func getConsumerGroups(): ArrayList<String> {
        let result = ArrayList<String>()
        for (g in consumerGroups) { result.add(g) }
        result
    }
    public func getCreateTime(): DateTime { createTime }
}

/**
 * 消费者注册信息，存储在 fleet /mq/consumes。
 */
@DataAssist[props fields]
public class ConsumerRegistration {
    private static let log = LoggerFactory.getLogger<ConsumerRegistration>()
    private var consumerId: String = ""
    private var groupId: String = ""
    // matchMode 作为 String 存储（编码为 "Exact:/order/create" 格式）
    private var matchModeStr: String = ""
    private var labels: ?ArrayList<String> = None
    private var dataFilter: ?String = None
    private var lastHeartbeat: DateTime = DateTime.now()
    public init() {}

    public init(consumerId!: String, groupId!: String, matchModeStr!: String,
                labels!: ?ArrayList<String>, dataFilter!: ?String,
                lastHeartbeat!: DateTime) {
        this.consumerId = consumerId
        this.groupId = groupId
        this.matchModeStr = matchModeStr
        this.labels = labels
        this.dataFilter = dataFilter
        this.lastHeartbeat = lastHeartbeat
    }

    public func getMatchMode(): MatchMode {
        decodeMatchMode(matchModeStr)
    }

    public func getLastHeartbeat(): DateTime { lastHeartbeat }

    public func getConsumerId(): String { consumerId }

    public func getGroupId(): String { groupId }

    private static func decodeMatchMode(s: String): MatchMode {
        if (s.startsWith("Exact:")) { MatchMode.Exact(s[6..]) }
        else if (s.startsWith("Glob:")) { MatchMode.Glob(s[5..]) }
        else if (s.startsWith("Prefix:")) { MatchMode.Prefix(s[7..]) }
        else {
            log.warn{"decodeMatchMode: unknown prefix, treating as Exact: ${s}"}
            MatchMode.Exact(s)
        }
    }
}

/**
 * Broker 节点信息，存储在 fleet /mq/brokers/<nodeId>。
 */
@DataAssist[props fields]
public class BrokerMeta {
    private var nodeId: String = ""
    private var host: String = ""
    private var port: Int64 = 0
    private var isMaster: Bool = false
    private var queues: ArrayList<String> = ArrayList()
    private var lastSeen: DateTime = DateTime.now()
    public init() {}
}

/**
 * 压缩类型。v1 恒为 None，为未来扩展预留。
 */
public enum CompressionType {
    | NoCompression
    | Zstd
}

/**
 * MQ 消息（内部表示，非 fleet 存储）。
 */
public struct Message {
    public Message(
        public let id!: MessageID = MessageID(),
        public let topic!: String = "",
        public let queueIndex!: Int64 = 0,
        public let labels!: ArrayList<String> = ArrayList(),
        public let payload!: Array<Byte> = [],
        public let producerId!: String = "",
        public let timestamp!: DateTime = DateTime.now(),
        public let expireAt!: ?DateTime = None,
        public let qos!: QoS = QoS.AtMostOnce,
        public let compression!: CompressionType = CompressionType.NoCompression
    ) {}
}

/**
 * 生产结果。
 */
public struct ProduceResult {
    public ProduceResult(
        public let messageId!: MessageID = MessageID()
    ) {}
}
