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
import std.collection.ArrayList
import std.io.{ByteBuffer, SeekPosition}
import std.sync.{Mutex, AtomicBool}

/**
 * MQ 客户端单例。
 * 连接 MQ 服务端，提供生产、订阅、消费 API。
 */
public class MqClient <: Resource {
    private static var instance: ?MqClient = None
    private static let instanceLock = Mutex()  // 保护 getInstance() 双重检查竞态
    private let log = LoggerFactory.getLogger('fountain::fmq.MqClient')

    // MQ 服务端连接
    let mqConn: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    // 订阅/消费管理器
    let sender: Sender
    let subscriber: Subscriber
    let consumer: Consumer
    let syncRegistry: SyncRegistry

    private let config: MqConfig
    private let closed = AtomicBool(false)

    private init(config: MqConfig, mqConn: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>) {
        this.config = config
        this.mqConn = mqConn
        this.sender = Sender(mqConn)
        this.subscriber = Subscriber(config, mqConn)
        this.consumer = Consumer(mqConn, subscriber)
        this.syncRegistry = SyncRegistry(config, mqConn)
    }

    /**
     * 获取单例实例，synchronized 防止并发创建竞态。
     */
    public static func getInstance(config: MqConfig): MqClient {
        if (let Some(inst) <- instance) { return inst }
        synchronized(instanceLock) {
            if (let Some(inst) <- instance) { return inst }

            let hostPort = if (config.mqHosts.size > 0) { config.mqHosts[0] } else { "" }
            let parts = hostPort.split(':')
            if (parts.size != 2) {
                throw MqException("invalid mq_hosts: ${config.mqHosts}")
            }

            let conn = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
                queueSize: 1024,
                socketCount: 1,
                host: parts[0],
                port: UInt16.parse(parts[1]),
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 30,
                checker: { buffer => true }
            ).noDelay(true).build()

            let inst = MqClient(config, conn)
            instance = inst
            inst
        }
    }

    // ───── 生产 API ─────

    public func produce(topic: String, labels: ArrayList<String>, data: Array<Byte>): ProduceResult {
        sender.produce(topic, labels, data)
    }

    /**
     * 批量生产消息。
     */
    public func produceBatch(topic: String, messages: ArrayList<(ArrayList<String>, Array<Byte>)>): ArrayList<ProduceResult> {
        sender.produceBatch(topic, messages)
    }

    // ───── 订阅 API ─────

    public func subscribe(groupId: String, matchMode: MatchMode): Bool {
        subscriber.subscribe(groupId, matchMode, labels: ArrayList())
    }

    public func subscribe(groupId: String, matchMode: MatchMode, labels!: ArrayList<String> = ArrayList()): Bool {
        subscriber.subscribe(groupId, matchMode, labels: labels)
    }

    public func subscribe(groupId: String, matchMode: MatchMode, dataFilter!: String = ""): Bool {
        subscriber.subscribe(groupId, matchMode, dataFilter: dataFilter)
    }

    public func unsubscribe(groupId: String, matchMode: MatchMode): Bool {
        subscriber.unsubscribe(groupId, matchMode)
    }

    public func deregister(groupId: String, consumerId: String): Bool {
        subscriber.deregister(groupId, consumerId)
    }

    // ───── 消费 API ─────

    public func poll<T>(timeout: Duration): ?Message where T <: DataFields<T> {
        consumer.poll<T>(timeout)
    }

    public func ack(msgId: String, topic: String, queueIndex: Int64): Bool {
        consumer.ack(msgId, topic, queueIndex)
    }

    public func ackBatch(acks: ArrayList<(String, String, Int64)>): Bool {
        consumer.ackBatch(acks)
    }

    // ───── 死信队列 API ─────

    /**
     * 列出死信。
     */
    public func listDeadLetters(topic: String, queueIndex: Int64): ArrayList<(String, Array<Byte>)> {
        let payload = encodeDlqPayload(topic, queueIndex)
        let req = ProtocolMessage(Command.DLQ_LIST, MessageID(),
            MqBody("dlq_list", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                return decodeDeadLetterList(body.payload)
            }
        }
        ArrayList()
    }

    /**
     * 重投单条死信。
     */
    public func redeliverDeadLetter(topic: String, queueIndex: Int64, messageId: String): Bool {
        let payload = encodeDlqRedeliverPayload(topic, queueIndex, messageId)
        let req = ProtocolMessage(Command.DLQ_REDELIVER, MessageID(),
            MqBody("dlq_redeliver", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        resp.isSome()
    }

    /**
     * 重投所有死信。
     */
    public func redeliverAllDeadLetters(topic: String, queueIndex: Int64): Bool {
        let payload = encodeDlqPayload(topic, queueIndex)
        let req = ProtocolMessage(Command.DLQ_REDELIVER_ALL, MessageID(),
            MqBody("dlq_redeliver_all", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        resp.isSome()
    }

    // ───── 主题管理 API ─────

    public func createTopic(name: String, queueCount!: Int64 = 1): Bool {
        let payload = encodeTopicOpPayload("create", name, queueCount)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        mqConn.transfer(req.id, req, Duration.second * 10).isSome()
    }

    public func deleteTopic(name: String): Bool {
        let payload = encodeTopicOpPayload("delete", name, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        mqConn.transfer(req.id, req, Duration.second * 10).isSome()
    }

    public func listTopics(): ArrayList<String> {
        let payload = encodeTopicOpPayload("list", "", 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                return decodeTopicList(body.payload)
            }
        }
        ArrayList()
    }

    /**
     * 列出指定主题的在线消费者。
     * @return ArrayList<(consumerId, groupId, matchMode)>
     */
    public func listConsumers(topic: String): ArrayList<(String, String, String)> {
        let payload = encodeTopicOpPayload("listConsumers", topic, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                return decodeConsumerList(body.payload)
            }
        }
        ArrayList()
    }

    /**
     * 添加消费者组到主题。
     */
    public func addConsumerGroup(topic: String, group: String): Bool {
        let payload = encodeGroupOpPayload("addGroup", topic, group, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        mqConn.transfer(req.id, req, Duration.second * 10).isSome()
    }

    /**
     * 从主题移除消费者组。
     */
    public func removeConsumerGroup(topic: String, group: String): Bool {
        let payload = encodeGroupOpPayload("removeGroup", topic, group, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        mqConn.transfer(req.id, req, Duration.second * 10).isSome()
    }

    /**
     * 查看主题详情。
     * 服务端返回的 topic_info 是二进制编码数据，以 hex 格式显示。
     */
    public func showTopic(name: String): ?String {
        let payload = encodeTopicOpPayload("showTopic", name, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data) && body.bodyType == "topic_info") {
                return Some(toHexString(body.payload))
            }
        }
        None
    }

    /**
     * 将二进制数据转为 hex 格式字符串。
     */
    private static func toHexString(data: Array<Byte>): String {
        let result = ArrayList<UInt8>()
        for (b in data) {
            let hi = b >> 4 & 0x0Fu8
            let lo = b & 0x0Fu8
            result.add(if (hi < 10u8) { hi + 0x30u8 } else { hi - 10u8 + 0x61u8 })
            result.add(if (lo < 10u8) { lo + 0x30u8 } else { lo - 10u8 + 0x61u8 })
        }
        String.fromUtf8(result.unsafeData())
    }

    /**
     * 重置消费者组 offset。
     */
    public func resetOffset(topic: String, group: String, offset: Int64, queueIndex!: Int64 = 0): Bool {
        let payload = encodeGroupOpPayload("resetOffset", topic, group, offset, queueIndex: queueIndex)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        mqConn.transfer(req.id, req, Duration.second * 10).isSome()
    }

    /**
     * 列出指定主题的消费者组。
     */
    public func listGroups(topic: String): ArrayList<String> {
        let payload = encodeTopicOpPayload("listGroups", topic, 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                return decodeTopicList(body.payload)
            }
        }
        ArrayList()
    }

    /**
     * 列出所有 topic 的消费者组（单次 RPC 批量查询）。
     * @return ArrayList<(topic, groupName)>
     */
    public func listAllConsumerGroups(): ArrayList<(String, String)> {
        let payload = encodeTopicOpPayload("listAllGroups", "", 0)
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", payload).toData())
        let resp = mqConn.transfer(req.id, req, Duration.second * 10)
        if (let Some(r) <- resp) {
            if (let Some(body) <- convert<MqBody>(r.data)) {
                return decodeAllGroupList(body.payload)
            }
        }
        ArrayList()
    }

    // ───── 生命周期 ─────

    public func close(): Unit {
        if (closed.load()) { return }
        closed.store(true)
        syncRegistry.stopHeartbeat()
        mqConn.close()
        synchronized(instanceLock) {
            instance = None
        }
    }

    public func isClosed(): Bool { closed.load() }

    // ───── 协议编解码 ─────

    private static func encodeDlqPayload(topic: String, queueIndex: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(topic).encode(queueIndex)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeTopicOpPayload(op: String, name: String, queueCount: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(op).encode(name).encode(queueCount)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeGroupOpPayload(op: String, topic: String, group: String, offset: Int64, queueIndex!: Int64 = 0): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(op).encode(topic).encode(group).encode(offset).encode(queueIndex)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeDlqRedeliverPayload(topic: String, queueIndex: Int64, msgId: String): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(topic).encode(queueIndex).encode(msgId)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private func decodeDeadLetterList(data: Array<Byte>): ArrayList<(String, Array<Byte>)> {
        let result = ArrayList<(String, Array<Byte>)>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(msgId) <- dec.decode<String>(buf)
                        && let Some(msgData) <- dec.decode<Array<Byte>>(buf)) {
                        result.add((msgId, msgData))
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeDeadLetterList failed: ${e.message}"}
        }
        result
    }

    private func decodeTopicList(data: Array<Byte>): ArrayList<String> {
        let result = ArrayList<String>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(t) <- dec.decode<String>(buf)) {
                        result.add(t)
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeTopicList failed: ${e.message}"}
        }
        result
    }

    private func decodeConsumerList(data: Array<Byte>): ArrayList<(String, String, String)> {
        let result = ArrayList<(String, String, String)>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(consumerId) <- dec.decode<String>(buf)
                        && let Some(groupId) <- dec.decode<String>(buf)
                        && let Some(matchMode) <- dec.decode<String>(buf)) {
                        result.add((consumerId, groupId, matchMode))
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeConsumerList failed: ${e.message}"}
        }
        result
    }

    private func decodeAllGroupList(data: Array<Byte>): ArrayList<(String, String)> {
        let result = ArrayList<(String, String)>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(topicCount) <- dec.decode<Int64>(buf)) {
                for (_ in 0..topicCount) {
                    if (let Some(topic) <- dec.decode<String>(buf)
                        && let Some(groupCount) <- dec.decode<Int64>(buf)) {
                        for (_ in 0..groupCount) {
                            if (let Some(group) <- dec.decode<String>(buf)) {
                                result.add((topic, group))
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            log.warn{"decodeAllGroupList failed: ${e.message}"}
        }
        result
    }

}
