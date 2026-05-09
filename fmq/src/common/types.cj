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
 * 主题元数据，存储在 fsync /mq/topic/<topic>。
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
}

/**
 * 消费者注册信息，存储在 fsync /mq/consumes。
 */
@DataAssist[props fields]
public class ConsumerRegistration {
    private var consumerId: String = ""
    private var groupId: String = ""
    // matchMode 作为 String 存储（编码为 "Exact:/order/create" 格式）
    private var matchModeStr: String = ""
    private var labels: ?ArrayList<String> = None
    private var dataFilter: ?String = None
    private var lastHeartbeat: DateTime = DateTime.now()
    public init() {}

    public func getMatchMode(): MatchMode {
        decodeMatchMode(matchModeStr)
    }

    private static func encodeMatchMode(mode: MatchMode): String {
        match (mode) {
            case Exact(p) => "Exact:${p}"
            case Glob(p) => "Glob:${p}"
            case Prefix(p) => "Prefix:${p}"
        }
    }

    private static func decodeMatchMode(s: String): MatchMode {
        if (s.startsWith("Exact:")) { MatchMode.Exact(s[6..]) }
        else if (s.startsWith("Glob:")) { MatchMode.Glob(s[5..]) }
        else if (s.startsWith("Prefix:")) { MatchMode.Prefix(s[7..]) }
        else { MatchMode.Exact(s) }
    }
}

/**
 * Broker 节点信息，存储在 fsync /mq/brokers/<nodeId>。
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
 * MQ 消息（内部表示，非 fsync 存储）。
 */
public struct Message {
    public Message(
        public let id!: MessageID = MessageID(),
        public let topic!: String = "",
        public let labels!: ArrayList<String> = ArrayList(),
        public let payload!: Array<Byte> = [],
        public let producerId!: String = "",
        public let timestamp!: DateTime = DateTime.now(),
        public let expireAt!: ?DateTime = None,
        public let qos!: QoS = QoS.AtMostOnce
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
