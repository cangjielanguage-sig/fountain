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
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.path.DataPath
import fountain::f_data.{DataList, Data}
import std.io.{ByteBuffer, SeekPosition}

/**
 * 消费者。
 * 通过 CONSUME / ACK 命令与 MQ 服务端交互。
 */
public class Consumer {
    private let log = LoggerFactory.getLogger('fountain::fmq.Consumer')
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let subscriber: Subscriber

    public init(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                subscriber: Subscriber) {
        this.client = client
        this.subscriber = subscriber
    }

    /**
     * 拉取消息。
     * 遍历活跃订阅，发送 CONSUME 命令。
     */
    public func poll<T>(timeout: Duration): ?Message where T <: DataFields<T> {
        let subs = subscriber.getSubscriptions()
        if (subs.size == 0) {
            return None
        }
        for ((groupId, topic, dataFilter) in subs) {
            let payload = encodeConsumePayload(topic, groupId, 1)
            let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
                MqBody("consume", payload).toData())
            let resp = client.transfer(req.id, req, timeout)
            if (let Some(r) <- resp) {
                if (let Some(body) <- convert<MqBody>(r.data)) {
                    if (body.bodyType == "consume") {
                        let msgs = decodeMessageList(body.payload)
                        if (msgs.size > 0) {
                            let msgData = msgs[0]
                            // dataFilter 过滤
                            if (dataFilter != "" && !dataFilterMatch(dataFilter, msgData)) {
                                // 不匹配则跳过（自动 ACK 已由服务端处理）
                                continue
                            }
                            return Some(Message(
                                topic: topic, id: MessageID(),
                                queueIndex: 0,
                                payload: msgData, labels: ArrayList()))
                        }
                    }
                }
            }
        }
        None
    }

    /**
     * 应用 DataPath 过滤器。
     * 将消息体解码为通用 Data 树，执行 DataPath 表达式匹配。
     */
    private static func dataFilterMatch(filter: String, payload: Array<Byte>): Bool {
        try {
            let buf = ByteBuffer(payload)
            let codec = DefaultCodec()
            let dataTree = codec.decodeData(buf)
            let path = DataPath.cache(filter)
            let wrapper = DataList()
            wrapper.add(dataTree)
            path.get(wrapper).next().isSome()
        } catch (_: Exception) {
            true  // 解码失败时不过滤（保留消息）
        }
    }

    /**
     * 确认消息。
     * @param topic 所属 topic
     * @param queueIndex 所属队列索引
     */
    public func ack(messageId: MessageID, topic: String, queueIndex: Int64): Bool {
        let idStr = messageIdToStr(messageId)
        let payload = encodeAckPayload(idStr, topic, queueIndex)
        let req = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("ack", payload).toData())
        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (resp.isSome()) {
            log.debug{"acked ${idStr}"}
            true
        } else {
            log.warn{"ack failed for ${idStr}"}
            false
        }
    }

    /**
     * 批量确认消息。
     * 合并为单次 ACK 命令，bodyType="batch_ack"。
     */
    public func ackBatch(acks: ArrayList<(MessageID, String, Int64)>): Bool {
        // 编码批量 ACK
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(acks.size)
        for ((msgId, topic, queueIndex) in acks) {
            enc.encode(messageIdToStr(msgId)).encode(topic).encode(queueIndex)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)

        let req = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("batch_ack", raw).toData())
        client.transfer(req.id, req, Duration.second * 10).isSome()
    }

    // ───── 编码工具 ─────

    internal static func encodeConsumePayload(topic: String, groupId: String, batchSize: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(topic).encode(groupId).encode(batchSize)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    internal static func encodeAckPayload(msgId: String, topic: String, queueIndex: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(msgId).encode(topic).encode(queueIndex)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    internal static func decodeMessageList(data: Array<Byte>): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(msg) <- dec.decode<Array<Byte>>(buf)) {
                        result.add(msg)
                    }
                }
            }
        } catch (_: Exception) {}
        result
    }

    private static func messageIdToStr(id: MessageID): String {
        "${id.pid}:${id.tid}"
    }

}

/**
 * 消费循环（Push 模式）。
 * 后台线程持续拉取消息，通过回调派发给业务层。
 */
public class ConsumerLoop {
    private let log = LoggerFactory.getLogger('fountain::fmq.ConsumerLoop')
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let subscriber: Subscriber
    private let groupId: String
    private let topic: String
    private let dataFilter: String
    private let callback: (Message) -> Unit
    private var running: Bool = false
    private var closed: Bool = false

    public init(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                subscriber: Subscriber, groupId: String, topic: String,
                callback: (Message) -> Unit,
                dataFilter!: String = "") {
        this.client = client
        this.subscriber = subscriber
        this.groupId = groupId
        this.topic = topic
        this.dataFilter = dataFilter
        this.callback = callback
    }

    /**
     * 启动后台消费线程。
     */
    public func start(): Unit {
        if (running) { return }
        running = true
        closed = false
        let selfRef = this
        spawn {
            while (!selfRef.closed) {
                try {
                    selfRef.pollOnce()
                } catch (e: Exception) {
                    selfRef.log.error{"ConsumerLoop error: ${e.message}"}
                    sleep(Duration.millisecond * 100)
                }
            }
            selfRef.running = false
        }
        log.info{"ConsumerLoop started: ${groupId}/${topic}"}
    }

    /**
     * 停止消费循环。
     */
    public func close(): Unit {
        closed = true
        log.info{"ConsumerLoop closed: ${groupId}/${topic}"}
    }

    public func isRunning(): Bool { running }

    /**
     * 单次拉取：CONSUME → dataFilter → callback → ACK。
     */
    private func pollOnce(): Unit {
        let payload = Consumer.encodeConsumePayload(topic, groupId, 1)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", payload).toData())
        let resp = client.transfer(req.id, req, Duration.second * 5)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                if (body.bodyType == "consume") {
                    let msgs = Consumer.decodeMessageList(body.payload)
                    if (msgs.size > 0) {
                        let msgData = msgs[0]
                        // dataFilter 过滤
                        if (dataFilter != "" && !dataFilterMatchImpl(dataFilter, msgData)) {
                            return  // 不匹配，跳过
                        }
                        let msg = Message(topic: topic, id: MessageID(),
                            queueIndex: 0, payload: msgData, labels: ArrayList())
                        callback(msg)
                        // ACK
                        let ackPayload = Consumer.encodeAckPayload(
                            "${msg.id.pid}:${msg.id.tid}", topic, 0)
                        let ackReq = ProtocolMessage(Command.ACK, MessageID(),
                            MqBody("ack", ackPayload).toData())
                        client.transfer(ackReq.id, ackReq, Duration.second * 5)
                    }
                }
            }
        }
    }

    /** 复制 Consumer.dataFilterMatch 的逻辑用于 ConsumerLoop */
    private static func dataFilterMatchImpl(filter: String, payload: Array<Byte>): Bool {
        try {
            let buf = ByteBuffer(payload)
            let codec = DefaultCodec()
            let dataTree = codec.decodeData(buf)
            let path = DataPath.cache(filter)
            let wrapper = DataList()
            wrapper.add(dataTree)
            path.get(wrapper).next().isSome()
        } catch (_: Exception) {
            true
        }
    }
}
