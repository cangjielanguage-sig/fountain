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
package fountain::fmq.client

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * 消费者。
 * 提供 poll 拉取和 ACK 确认。
 */
public class Consumer {
    private let log = LoggerFactory.getLogger('fountain::fmq.Consumer')
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, DataAny, MessageID>
    private let subscriber: Subscriber

    public init(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, DataAny, MessageID>,
                subscriber: Subscriber) {
        this.client = client
        this.subscriber = subscriber
    }

    /**
     * 拉取消息。
     * T 为消息数据解码类型，用于 dataFilter 过滤。
     */
    public func poll<T>(timeout: Duration): ?Message where T <: DataFields<T> {
        log.debug{"poll (placeholder)"}
        // Phase 7: 发送 CONSUME 命令，等待响应
        // 响应消息后，用 dataFilterMatch<T> 过滤
        None
    }

    /**
     * 确认消息。
     */
    public func ack(messageId: MessageID): Bool {
        log.debug{"ack (placeholder)"}
        // Phase 7: 发送 ACK 命令
        true
    }
}
