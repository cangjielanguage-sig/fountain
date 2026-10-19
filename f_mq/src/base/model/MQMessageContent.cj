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
package fountain::f_mq.base.model

import fountain::f_data.*

/** 一条记录解码后的四元组。 */
public struct MQMessageContent {
    public let topic: String
    public let tags: Array<String>
    public let messageId: String
    public let body: DataAny

    public init(topic: String, tags: Array<String>, messageId: String, body: DataAny) {
        this.topic = topic
        this.tags = tags
        this.messageId = messageId
        this.body = body
    }

    /** 补上服务端位置（队列 + 段 + 偏移），转成客户端可见的 `MQMessage`。 */
    public func toMessage(queueIndex: Int64, segmentedIndex: Int64, segmentedOffset: Int64): MQMessage {
        MQMessage(topic, tags, Some(body), queueIndex, segmentedIndex, segmentedOffset)
    }
}
