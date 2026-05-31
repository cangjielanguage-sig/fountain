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
import std.sync.{AtomicBool, Mutex}

/**
 * 消费者。
 * 通过 CONSUME / ACK 命令与 MQ 服务端交互。
 */
public class Consumer {
    private static let log = LoggerFactory.getLogger<Consumer>()
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let subscriber: Subscriber
    /** P2-2: 批量 CONSUME 缓存的剩余消息，避免丢弃后服务端重试。 */
    private var pendingMessages = ArrayList<(String, String, String, ArrayList<String>, Array<Byte>)>()
    private let msgLock = Mutex()

    public init(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                subscriber: Subscriber) {
        this.client = client
        this.subscriber = subscriber
    }

    /**
     * 拉取消息。
     * 遍历活跃订阅，发送 CONSUME 命令。
     */
    public func poll(timeout: Duration): ?Message {
        let subs = subscriber.getSubscriptions()
        // P2-2: 优先从缓存返回消息，减少 RPC (dequeuePending 内部已加锁)
        if (let Some(msg) <- dequeuePending(subs)) { return Some(msg) }
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
                    // 缓存所有消息，稍后返回第一个
                    for ((groupId, topic, dataFilter, _) in subs) {
                        if (let Some(groupMap) <- perTopic.get(topic) && let Some(msgs) <- groupMap.get(groupId)) {
                            for ((deliveryId, labels, payload) in msgs) {
                                if (dataFilter != "" && !Consumer.dataFilterMatch(dataFilter, payload)) {
                                    if (let Some(ackQi) <- ConsumerLoop.extractQueueIndex(deliveryId)) {
                                        Consumer.retryAck(client, deliveryId, topic, ackQi, "dataFilter")
                                    }
                                } else {
                                    synchronized(msgLock) {
                                        pendingMessages.add((topic, deliveryId, groupId, labels, payload))
                                    }
                                }
                            }
                        }
                    }
                    // dequeuePending 内部已加锁
                    if (let Some(msg) <- dequeuePending(subs)) { return Some(msg) }
                }
            }
        }
        None
    }

    /** P2-2: 从缓存取出一条消息，提取 queueIndex 并构建 Message。 */
    /** P3-5: subs 由调用方传入，避免 poll() 内重复调用 getSubscriptions()。 */
    private func dequeuePending(subs: ArrayList<(String, String, String, String)>): ?Message {
        var toAck = ArrayList<(String, String, Int64)>()
        var result: ?Message = None
        synchronized(msgLock) {
            while (pendingMessages.size > 0) {
                let (topic, deliveryId, groupId, labels, payload) = pendingMessages[0]
                pendingMessages.remove(at: 0)
                var active = false
                for ((g, t, _, _) in subs) {
                    if (g == groupId && t == topic) { active = true; break }
                }
                if (active) {
                    let qi = ConsumerLoop.extractQueueIndex(deliveryId) ?? 0
                    result = Some(Message(topic: topic, id: MessageID(),
                        queueIndex: qi, payload: payload, labels: labels,
                        producerId: deliveryId))
                    break
                }
                // P2-3: 已取消订阅的消息发送 ACK，防止服务端无限重试
                if (let Some(qi) <- ConsumerLoop.extractQueueIndex(deliveryId)) {
                    toAck.add((deliveryId, topic, qi))
                }
            }
        }
        for ((deliveryId, topic, qi) in toAck) {
            Consumer.retryAck(client, deliveryId, topic, qi, "unsubscribed")
        }
        result
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
            // P3-1: 异常不按"过滤不匹配"处理——返回 true 递送消息到回调，
            // 避免因解码器 BUG 或格式异常导致消息被静默丢弃。
            log.error{"dataFilterMatch error, treating as match and delivering to callback: ${e.message}"}
            true
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

    /**
     * 带重试的 ACK 发送，最多 3 次 + 100ms 退避。
     * 全部失败记录 warn 日志。
     */
    internal static func retryAck(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                                  deliveryId: String, topic: String, queueIndex: Int64, reason: String): Unit {
        for (_ in 0..3) {
            if (Consumer.sendAck(client, deliveryId, topic, queueIndex, reason)) { return }
            sleep(Duration.millisecond * 100)
        }
        Consumer.log.warn{"ACK failed after 3 retries (reason=${reason}), msg may be redelivered"}
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
    /** P2-8: 返回Bool支持调用方重试。 */
    internal static func sendAck(client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>,
                                 deliveryId: String, topic: String, queueIndex: Int64, logLabel: String): Bool {
        let ackPayload = Consumer.encodeAckPayload(deliveryId, topic, queueIndex)
        let ackReq = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("ack", ackPayload).toData())
        let ackResp = client.transfer(ackReq.id, ackReq, Duration.second * 5)
        if (ackResp.isNone()) {
            let label = logLabel
            log.warn{"${label} ACK failed for deliveryId=${deliveryId}"}
            false
        } else { true }
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
    private let threadLock = Mutex()
    private let threadFinished = AtomicBool(false)

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
     * P29-1: 整体 synchronized 消除 TOCTOU 竞态。
     */
    public func start(): Unit {
        synchronized(threadLock) {
            if (running.load()) { return }
            if (!threadFinished.load()) {
                log.warn{"ConsumerLoop re-start while old thread still running, skipping"}
                return
            }
            running.store(true)
            closed.store(false)
            threadFinished.store(false)  // P29-1: 重置标记，确保新线程的 finished 信号独立
            let selfRef = this
            threadFuture = spawn {
                while (!selfRef.closed.load() && !selfRef.client.isClosed()) {
                    try {
                        if (!selfRef.pollOnce()) {
                            sleep(Duration.millisecond * 100)
                        }
                    } catch (e: Exception) {
                        log.error{"ConsumerLoop error: ${e.message}"}
                        sleep(Duration.millisecond * 100)
                    }
                }
                selfRef.running.store(false)
                selfRef.threadFinished.store(true)
            }
        }
        log.info{"ConsumerLoop started: ${groupId}/${topic}"}
    }

    /**
     * 停止消费循环。
     */
    public func close(): Unit {
        synchronized(threadLock) {
            closed.store(true)  // P2-1: 移入锁内，防止 start() 在 close() 未完成时覆盖 close 信号
            if (let Some(f) <- threadFuture) {
                // P2-9: Future.get() 无 timeout，用 AtomicBool 轮询替代
                var waited: Int64 = 0
                while (waited < 50 && !threadFinished.load()) {  // 5s 上限
                    sleep(Duration.millisecond * 100)
                    waited += 1
                }
                if (!threadFinished.load()) {
                    log.warn{"ConsumerLoop thread did not exit within 5s, abandoning future"}
                }
                // P2-2: tryGet() 已消费 Future 值，不再调用 get() 避免双消费
                if (f.tryGet().isNone() && !threadFinished.load()) {
                    log.warn{"ConsumerLoop thread future not ready after wait"}
                }
                threadFuture = None
            }
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
                            if (let Some(ackQi) <- extractQueueIndex(deliveryId)) {
                                for (_ in 0..3) {
                                    if (Consumer.sendAck(client, deliveryId, topic, ackQi, "dataFilter")) { break }
                                    sleep(Duration.millisecond * 100)
                                }
                            }
                            return false  // P3-4: 返回 false 让外层循环 sleep，避免紧密循环
                        }
                        let queueIndex = extractQueueIndex(deliveryId) ?? 0
                        let msg = Message(topic: topic, id: MessageID(),
                            queueIndex: queueIndex, payload: msgData, labels: labels,
                            producerId: deliveryId)
                        callback(msg)
                        Consumer.retryAck(client, deliveryId, topic, queueIndex, "callback")
                        return true
                    }
                }
            }
        }
        false  // 无消息
    }

    /**
     * 从 deliveryId "topic:queueIndex:groupId:offset:sn" 提取 queueIndex。
     * queueIndex 固定为 parts[1]（topic 后的第二个字段），不用末尾反算。
     */
    internal static func extractQueueIndex(deliveryId: String): ?Int64 {
        let parts = deliveryId.split(':')
        if (parts.size >= 2 && let Some(idx) <- Int64.tryParse(parts[1])) {
            Some(idx)
        } else {
            log.warn{"extractQueueIndex: malformed deliveryId '${deliveryId}', returning None"}
            None
        }
    }

}
