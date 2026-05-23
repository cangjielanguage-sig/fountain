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
import std.collection.HashMap
import std.io.{ByteBuffer, SeekPosition}
import std.convert.*
import std.sync.AtomicBool

/**
 * 消费者。
 * 通过 CONSUME / ACK 命令与 MQ 服务端交互。
 */
public class Consumer {
    private static let log = LoggerFactory.getLogger<Consumer>()
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
        // 批量 CONSUME: 单次 RPC 拉取所有订阅的消息
        let batchPayload = Consumer.encodeBatchConsumePayload(subs)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("batch_consume", batchPayload).toData())
        if (let Some(r) <- client.transfer(req.id, req, timeout)) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                if (body.bodyType == "batch_consume") {
                    let perTopic = Consumer.decodeBatchConsumeResponse(body.payload)
                    for ((groupId, topic, dataFilter, _) in subs) {
                        if (let Some(groupMap) <- perTopic.get(topic) && let Some(msgs) <- groupMap.get(groupId)) {
                            for ((deliveryId, labels, payload) in msgs) {
                                if (dataFilter != "" && !Consumer.dataFilterMatch(dataFilter, payload)) {
                                    let ackQi = ConsumerLoop.extractQueueIndex(deliveryId)
                                    Consumer.sendAck(client, deliveryId, topic, ackQi, "dataFilter")
                                    continue
                                }
                                let qi = ConsumerLoop.extractQueueIndex(deliveryId)
                                return Some(Message(
                                    topic: topic, id: MessageID(),
                                    queueIndex: qi,
                                    payload: payload, labels: labels,
                                    producerId: deliveryId))
                            }
                        }
                    }
                }
                // TODO(P2-2): remaining messages in perTopic are lost on return, causing server retry.
            }
        }
        None
    }

    /**
     * 应用 DataPath 过滤器。
     * 将消息体解码为通用 Data 树，执行 DataPath 表达式匹配。
     */
    internal static func dataFilterMatch(filter: String, payload: Array<Byte>): Bool {
        try {
            let buf = ByteBuffer(payload)
            let codec = DefaultCodec()
            let dataTree = codec.decodeData(buf)
            let path = DataPath.cache(filter)
            let wrapper = DataList()
            wrapper.add(dataTree)
            path.get(wrapper).next().isSome()
        } catch (e: Exception) {
            log.warn{"dataFilterMatch decode failed: ${e.message}"}
            false
        }
    }

    /**
     * 确认消息。
     * @param topic 所属 topic
     * @param queueIndex 所属队列索引
     */
    public func ack(msgId: String, topic: String, queueIndex: Int64): Bool {
        let payload = encodeAckPayload(msgId, topic, queueIndex)
        let req = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("ack", payload).toData())
        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (resp.isSome()) {
            log.debug{"acked ${msgId}"}
            true
        } else {
            log.warn{"ack failed for ${msgId}"}
            false
        }
    }

    /**
     * 批量确认消息。
     * 合并为单次 ACK 命令，bodyType="batch_ack"。
     */
    public func ackBatch(acks: ArrayList<(String, String, Int64)>): Bool {
        // 编码批量 ACK
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(acks.size)
        for ((msgId, topic, queueIndex) in acks) {
            enc.encode(msgId).encode(topic).encode(queueIndex)
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

    internal static func encodeBatchConsumePayload(subs: ArrayList<(String, String, String, String)>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode(subs.size)
        for ((groupId, topic, _, _) in subs) {
            enc.encode(topic).encode(groupId).encode(1i64)  // batchSize=1 per topic
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    internal static func encodeAckPayload(msgId: String, topic: String, queueIndex: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(msgId).encode(topic).encode(queueIndex)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /** P4-3: 发送 ACK（static 以便 ConsumerLoop 复用）。 */
    internal static func sendAck(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                                 deliveryId: String, topic: String, queueIndex: Int64, logLabel: String): Unit {
        let ackPayload = Consumer.encodeAckPayload(deliveryId, topic, queueIndex)
        let ackReq = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("ack", ackPayload).toData())
        let ackResp = client.transfer(ackReq.id, ackReq, Duration.second * 5)
        if (ackResp.isNone()) {
            let label = logLabel
            log.warn{"${label} ACK failed for deliveryId=${deliveryId}"}
        }
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
        } catch (e: Exception) {
            log.warn{"decodeMessageListWithLabels failed: ${e.message}"}
        }
        result
    }

    /**
     * 解码带 deliveryId 和 labels 的消息列表。
     * 格式：count + (deliveryId + labelCount + labels*N + data)*N
     */
    internal static func decodeMessageListWithLabels(data: Array<Byte>): ArrayList<(String, ArrayList<String>, Array<Byte>)> {
        let result = ArrayList<(String, ArrayList<String>, Array<Byte>)>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(deliveryId) <- dec.decode<String>(buf)
                        && let Some(labelCount) <- dec.decode<Int64>(buf)) {
                        let labels = ArrayList<String>()
                        var corrupted = false
                        for (_ in 0..labelCount) {
                            if (let Some(l) <- dec.decode<String>(buf)) {
                                labels.add(l)
                            } else {
                                corrupted = true
                                break
                            }
                        }
                        if (!corrupted && let Some(payload) <- dec.decode<Array<Byte>>(buf)) {
                            result.add((deliveryId, labels, payload))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeMessageListWithLabels failed: ${e.message}"}
        }
        result
    }

    /**
     * 解码批量 CONSUME 响应。
     * 格式: topicCount × [topic + groupId + msgCount × [deliveryId + labelCount + labels + data]]
     */
    internal static func decodeBatchConsumeResponse(data: Array<Byte>):
            HashMap<String, HashMap<String, ArrayList<(String, ArrayList<String>, Array<Byte>)>>> {
        let result = HashMap<String, HashMap<String, ArrayList<(String, ArrayList<String>, Array<Byte>)>>>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(topicCount) <- dec.decode<Int64>(buf)) {
                for (_ in 0..topicCount) {
                    if (let Some(topic) <- dec.decode<String>(buf)
                        && let Some(groupId) <- dec.decode<String>(buf)
                        && let Some(msgCount) <- dec.decode<Int64>(buf)) {
                        let msgs = ArrayList<(String, ArrayList<String>, Array<Byte>)>()
                        for (_ in 0..msgCount) {
                            if (let Some(deliveryId) <- dec.decode<String>(buf)
                                && let Some(labelCount) <- dec.decode<Int64>(buf)) {
                                let labels = ArrayList<String>()
                                var corrupted = false
                                for (_ in 0..labelCount) {
                                    if (let Some(l) <- dec.decode<String>(buf)) { labels.add(l) }
                                    else {
                                        corrupted = true
                                        break
                                    }
                                }
                                if (!corrupted && let Some(payload) <- dec.decode<Array<Byte>>(buf)) {
                                    msgs.add((deliveryId, labels, payload))
                                }
                            }
                        }
                        if (let Some(groupMap) <- result.get(topic)) {
                            groupMap[groupId] = msgs
                        } else {
                            let groupMap = HashMap<String, ArrayList<(String, ArrayList<String>, Array<Byte>)>>()
                            groupMap[groupId] = msgs
                            result[topic] = groupMap
                        }
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeBatchConsumeResponse failed: ${e.message}"}
        }
        result
    }


}

/**
 * 消费循环（Push 模式）。
 * 后台线程持续拉取消息，通过回调派发给业务层。
 */
public class ConsumerLoop {
    private static let log = LoggerFactory.getLogger<ConsumerLoop>()
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let subscriber: Subscriber
    private let groupId: String
    private let topic: String
    private let dataFilter: String
    private let callback: (Message) -> Unit
    private let running = AtomicBool(false)
    private let closed = AtomicBool(false)
    private var threadFuture: ?Future<Unit> = None

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
        if (running.load()) { return }
        running.store(true)
        closed.store(false)
        let selfRef = this
        threadFuture = spawn {
            while (!selfRef.closed.load() && !selfRef.client.isClosed()) {
                try {
                    if (!selfRef.pollOnce()) {
                        sleep(Duration.millisecond * 100)  // P3-2: 无消息时退避
                    }
                } catch (e: Exception) {
                    log.error{"ConsumerLoop error: ${e.message}"}
                    sleep(Duration.millisecond * 100)
                }
            }
            selfRef.running.store(false)
        }
        log.info{"ConsumerLoop started: ${groupId}/${topic}"}
    }

    /**
     * 停止消费循环。
     */
    public func close(): Unit {
        closed.store(true)
        if (let Some(f) <- threadFuture) {
            f.get()
        }
        log.info{"ConsumerLoop closed: ${groupId}/${topic}"}
    }

    public func isRunning(): Bool { running.load() }

    /**
     * 单次拉取：CONSUME → dataFilter → callback → ACK。
     * 使用 decodeMessageListWithLabels 获取服务端 deliveryId 和 labels。
     */
    private func pollOnce(): Bool {
        let payload = Consumer.encodeConsumePayload(topic, groupId, 1)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", payload).toData())
        let resp = client.transfer(req.id, req, Duration.second * 5)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                if (body.bodyType == "consume") {
                    let msgs = Consumer.decodeMessageListWithLabels(body.payload)
                    if (msgs.size > 0) {
                        let (deliveryId, labels, msgData) = msgs[0]
                        if (dataFilter != "" && !Consumer.dataFilterMatch(dataFilter, msgData)) {
                            let ackQi = extractQueueIndex(deliveryId)
                            Consumer.sendAck(client, deliveryId, topic, ackQi, "dataFilter")
                            return true
                        }
                        let queueIndex = extractQueueIndex(deliveryId)
                        let msg = Message(topic: topic, id: MessageID(),
                            queueIndex: queueIndex, payload: msgData, labels: labels,
                            producerId: deliveryId)
                        callback(msg)
                        Consumer.sendAck(client, deliveryId, topic, queueIndex, "callback")
                        return true
                    }
                }
            }
        }
        false  // 无消息
    }

    /**
     * 从 deliveryId "topic:queueIndex:groupId:offset:sn" 提取 queueIndex。
     * queueIndex 始终是第 2 个字段 (索引 1)。
     */
    internal static func extractQueueIndex(deliveryId: String): Int64 {
        let parts = deliveryId.split(':')
        if (parts.size >= 2 && let Some(idx) <- Int64.tryParse(parts[1])) {
            idx
        } else {
            0
        }
    }

}
