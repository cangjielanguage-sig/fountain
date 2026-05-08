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

/**
 * 编码生产消息。
 */
public func encodeProduce(msg: Message): EncodedMessage {
    Message.publish(dup: false, qos: msg.qos, retain: false, data: msg)
}

/**
 * 编码 ACK 确认。
 */
public func encodeAck(msgId: MessageID): EncodedMessage {
    Message.ack(data: msgId)
}

/**
 * 编码心跳 PING。
 */
public func encodePing(): EncodedMessage {
    Message.ping()
}

/**
 * 编码 CONSUME 请求。
 */
public func encodeConsume(consumerId: String): EncodedMessage {
    Message.consume(once: false, qos: QoS.AtLeastOnce, data: consumerId)
}

/**
 * 编码 SUBSCRIBE 请求。
 */
public func encodeSubscribe(reg: ConsumerRegistration): EncodedMessage {
    Message.subscribe(data: reg)
}

/**
 * 编码 UNSUBSCRIBE 请求。
 */
public func encodeUnsubscribe(consumerId: String): EncodedMessage {
    Message.unsubscribe(data: consumerId)
}

/**
 * 编码 REGISTER 请求。
 */
public func encodeRegister(producerId: String): EncodedMessage {
    Message.register(data: producerId)
}

/**
 * 编码 DEREGISTER 请求。
 */
public func encodeDeregister(producerId: String): EncodedMessage {
    Message.deregister(data: producerId)
}

/**
 * 编码 SLAVEOF 请求。
 */
public func encodeSlaveOf(nodeId: String): EncodedMessage {
    Message.slaveof(reg: true, ack: false, data: nodeId)
}

/**
 * 编码 ELECT 消息。
 */
public func encodeElect(vote!: Bool, approve!: Bool, assume!: Bool, ack!: Bool, nodeId: String): EncodedMessage {
    Message.elect(vote: vote, approve: approve, assume: assume, ack: ack, data: nodeId)
}
