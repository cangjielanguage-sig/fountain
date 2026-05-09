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

import fountain::f_protocol.default.Message as ProtocolMessage
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}

/**
 * 协议命令封装工具方法。
 * 各命令的 payload 统一使用 DefaultCodec 编码为 MqBody。
 */

/**
 * 编码心跳 PING。
 */
public func encodePing(): EncodedMessage {
    ProtocolMessage.ping()
}

/**
 * 编码 PUBLISH 消息。
 */
public func encodePublish(topic: String, labels: ArrayList<String>, payload: Array<Byte>): ProtocolMessage {
    let bodyBytes = encodeProduceBytes(topic, labels, payload)
    ProtocolMessage(Command.PUBLISH(0), MessageID(),
        MqBody("produce", bodyBytes).toData())
}

/**
 * 编码 SUBSCRIBE 消息。
 */
public func encodeSubscribe(groupId: String, matchMode: MatchMode): ProtocolMessage {
    let modeStr = matchModeToString(matchMode)
    let topic = matchModeTopic(matchMode)
    let body = ByteBuffer()
    DefaultCodec().encode(topic).encode(modeStr)
        .finish().copy(to: body, closeFromOnEnd: true, closeToOnEnd: false)
    let raw = extractBytes(body)
    ProtocolMessage(Command.SUBSCRIBE, MessageID(),
        MqBody("subscribe", raw).toData())
}

/**
 * 编码 CONSUME 拉取消息。
 */
public func encodeConsume(topic: String, groupId: String, batchSize: Int64): ProtocolMessage {
    let body = ByteBuffer()
    DefaultCodec().encode(topic).encode(groupId).encode(batchSize)
        .finish().copy(to: body, closeFromOnEnd: true, closeToOnEnd: false)
    ProtocolMessage(Command.CONSUME(0), MessageID(),
        MqBody("consume", extractBytes(body)).toData())
}

/**
 * 编码 ACK 确认。
 */
public func encodeAck(msgId: String, topic: String, queueIndex: Int64): ProtocolMessage {
    let body = ByteBuffer()
    DefaultCodec().encode(msgId).encode(topic).encode(queueIndex)
        .finish().copy(to: body, closeFromOnEnd: true, closeToOnEnd: false)
    ProtocolMessage(Command.ACK, MessageID(),
        MqBody("ack", extractBytes(body)).toData())
}

// ───── 内部工具 ─────

private func encodeProduceBytes(topic: String, labels: ArrayList<String>, payload: Array<Byte>): Array<Byte> {
    let buf = ByteBuffer()
    let enc = DefaultCodec()
        .encode(topic)
        .encode(labels.size)
    for (l in labels) {
        enc.encode(l)
    }
    enc.encode(payload)
        .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
    extractBytes(buf)
}

private func matchModeToString(mode: MatchMode): String {
    match (mode) {
        case Exact(_) => "exact"
        case Glob(_) => "glob"
        case Prefix(_) => "prefix"
    }
}

private func matchModeTopic(mode: MatchMode): String {
    match (mode) {
        case Exact(t) => t
        case Glob(t) => t
        case Prefix(t) => t
    }
}

private func extractBytes(buf: ByteBuffer): Array<Byte> {
    let size = buf.seek(SeekPosition.End(0))
    buf.seek(SeekPosition.Begin(0))
    let raw = Array<Byte>(Int64(size), repeat: 0u8)
    buf.read(raw)
    raw
}
