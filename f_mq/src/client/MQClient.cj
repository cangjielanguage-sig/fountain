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
package fountain::f_mq.client

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import fountain::f_data.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.*
import fountain::f_protocol.default.*
import fountain::f_util.UUID

/**
 * MQ 客户端主入口。
 *
 * 节点表顺序即节点下标；连接懒建，初始化阶段不主动连任何节点，
 * 避免「一个节点抖动导致客户端无法启动」。
 */
public class MQClient <: Resource {
    private static let PUBLISH_TIMEOUT = Duration.second * 5
    private static let SUBSCRIBE_TIMEOUT = Duration.second * 5
    private static let CONSUME_TIMEOUT = Duration.second
    private static let ACK_TIMEOUT = Duration.second * 5
    private static let CONSUME_POLL_INTERVAL = Duration.millisecond * 200

    private let pool: MQNodePool
    private let ownership: MQOwnershipCache
    private let subscriptions = ConcurrentHashMap<String, MQSubscription>()
    private let closed = AtomicBool(false)
    private let closeLock = Mutex()

    /** 显式节点列表（测试 / 多集群场景）。 */
    public init(hosts: Array<String>) {
        this.pool = MQNodePool(hosts)
        this.ownership = MQOwnershipCache()
    }

    /** 从 `mqClient_hosts` 读取节点表。 */
    public init() {
        this(MQClientConfig.hosts)
    }

    // ===== 发布 =====

    /**
     * 发布消息。
     *
     * 先在本地校验主题，再编码记录并选择 owner 节点；`NOT_OWNER` 会换下一个节点重试，
     * 全部节点不可达抛 `MQConnectionException`。
     */
    public func publish<T>(topic: String, body: T, tags!: Array<String> = []): Unit where T <: ToData {
        ensureOpen()
        if (!MQTopic.isValid(topic)) {
            throw MQException("invalid topic '${topic}'")
        }
        // 用 UTC 生成 id：帧里的时间戳往返后按 UTC 表示，记录中的 MESSAGE_ID 才能与解码后的帧 id 逐字一致
        let id = MessageID(time: DateTime.nowUTC())
        let record = MQMessageRecord.encode(topic, tags, id.toString(), body)
        for (node in candidateNodes(topic)) {
            let response = transferOf(node, MQProtocol.publish(record, id: id), PUBLISH_TIMEOUT)
            match (response) {
                case None => ()
                case Some(msg) =>
                    let result = MQProtocol.asResult(msg)
                    if (result.code == MQErrorCode.OK) {
                        // 记下实际接受发布的节点，后续发布优先复用它
                        ownership.put(topic, [node])
                        return
                    }
                    if (result.code == MQErrorCode.NOT_OWNER) {
                        // 缓存可能过期：失效后继续尝试下一个节点
                        ownership.invalidate(topic)
                        continue
                    }
                    throw MQServiceException(result.code, result.message)
            }
        }
        throw MQConnectionException("cannot publish to any node of topic '${topic}'")
    }

    // ===== 订阅 =====

    /**
     * 订阅主题：生成 UUID，向所有节点广播同一份载荷，收集接受者作为 owner 集合。
     *
     * 未注册订阅组（`GROUP_NOT_EXIST`）会向已接受节点回滚后抛 `MQServiceException`。
     */
    public func subscribe(topic: String, subscribeGroup!: String = '', tags!: Array<String> = [],
        filter!: String = '', autoAck!: Bool = false): String {
        ensureOpen()
        if (!MQTopic.isValid(topic)) {
            throw MQException("invalid topic '${topic}'")
        }
        // 非法表达式在本地失败，不发请求
        let compiled = MQFilter.compile(filter)
        let subscribedId = UUID.random().toString()
        let payload = MQSubscribePayload(subscribedId, topic, subscribeGroup, tags, filter, autoAck)
        let accepted = ArrayList<Int64>()
        var fatal: ?MQServiceException = None
        for (node in 0..pool.size) {
            let response = transferOf(node, MQProtocol.subscribe(payload), SUBSCRIBE_TIMEOUT)
            if (let Some(msg) <- response) {
                let result = MQProtocol.asResult(msg)
                if (result.code == MQErrorCode.OK) {
                    accepted.add(node)
                } else if (result.code == MQErrorCode.NOT_OWNER) {
                    // 该节点没有此主题的队列，跳过
                } else {
                    fatal = Some(MQServiceException(result.code, result.message))
                }
            }
            if (fatal.isSome()) {
                break
            }
        }
        if (let Some(error) <- fatal) {
            rollback(subscribedId, accepted)
            throw error
        }
        if (accepted.size == 0) {
            throw MQConnectionException("no node owns topic '${topic}' or all nodes are unreachable")
        }
        let owners = accepted.toArray()
        subscriptions.add(subscribedId, MQSubscription(subscribedId, topic, subscribeGroup, tags, compiled,
            autoAck, owners))
        ownership.put(topic, owners)
        subscribedId
    }

    private func rollback(subscribedId: String, accepted: ArrayList<Int64>): Unit {
        let payload = MQUnsubscribePayload(subscribedId)
        for (node in accepted) {
            transferOf(node, MQProtocol.unsubscribe(payload), ACK_TIMEOUT)
        }
    }

    // ===== 消费 =====

    /**
     * 阻塞式消费：在 owner 集合上轮转，取不到消息时固定间隔重试。
     *
     * 收到的记录会解码为 `MQMessage` 并填入位置；`autoAck` 订阅不记录投递来源。
     */
    public func consume(subscribedId: String): MQMessage {
        ensureOpen()
        let sub = subscriptionOf(subscribedId)
        while (true) {
            ensureOpen()
            if (sub.owners.size == 0) {
                throw MQConnectionException("subscription '${subscribedId}' has no owner node")
            }
            let start = sub.nextStart()
            for (i in 0..sub.owners.size) {
                let node = sub.owners[(start + i) % sub.owners.size]
                let response = transferOf(node, MQProtocol.consume(MQConsumePayload(subscribedId)), CONSUME_TIMEOUT)
                if (let Some(msg) <- response) {
                    if (msg.command == Command.ERROR) {
                        let result = MQProtocol.asResult(msg)
                        if (result.code == MQErrorCode.SUBSCRIBE_NOT_EXIST) {
                            throw MQServiceException(result.code, result.message)
                        }
                        continue
                    }
                    if (let Some(result) <- MQProtocol.asConsumeResult(msg)) {
                        if (result.record.size == 0) {
                            continue
                        }
                        if (let Some(content) <- MQMessageRecord.decode(result.record)) {
                            if (!sub.autoAck) {
                                sub.deliveries.add(MQSubscription.keyOf(result.queueIndex, result.segmentedIndex,
                                    result.segmentedOffset), node)
                            }
                            return content.toMessage(result.queueIndex, result.segmentedIndex,
                                result.segmentedOffset)
                        }
                    }
                }
            }
            sleep(CONSUME_POLL_INTERVAL)
        }
        // 不可达
        throw MQConnectionException("unreachable")
    }

    /**
     * 确认消息。
     *
     * 位置只在单个队列内唯一，`queueIndex` 必须与消费时一致；优先发给投递该位置的节点
     * （命中即删）；未命中时向所有 owner 广播，忽略 `ACK_UNKNOWN`。
     */
    public func ack(subscribedId: String, queueIndex: Int64, segmentedIndex: Int64, segmentedOffset: Int64): Unit {
        ensureOpen()
        let sub = subscriptionOf(subscribedId)
        let payload = MQAckPayload(subscribedId, queueIndex, segmentedIndex, segmentedOffset)
        match (sub.deliveries.remove(MQSubscription.keyOf(queueIndex, segmentedIndex, segmentedOffset))) {
            case Some(node) =>
                transferOf(node, MQProtocol.ack(payload), ACK_TIMEOUT)
            case None =>
                for (node in sub.owners) {
                    transferOf(node, MQProtocol.ack(payload), ACK_TIMEOUT)
                }
        }
    }

    // ===== 退订与生命周期 =====

    /**
     * 退订：向该订阅的所有 owner 发送 `UNSUBSCRIBE` 并删除本地订阅。
     *
     * 服务端回 `SUBSCRIBE_NOT_EXIST` 视为成功；本地不存在的 id 直接抛异常且不发请求。
     */
    public func unsubscribe(subscribedId: String): Unit {
        ensureOpen()
        let sub = match (subscriptions.remove(subscribedId)) {
            case Some(s) => s
            case None => throw MQServiceException(MQErrorCode.SUBSCRIBE_NOT_EXIST,
                "subscription '${subscribedId}' does not exist")
        }
        let payload = MQUnsubscribePayload(subscribedId)
        for (node in sub.owners) {
            transferOf(node, MQProtocol.unsubscribe(payload), ACK_TIMEOUT)
        }
    }

    /** 幂等关闭：关闭全部节点连接并清空订阅。 */
    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        synchronized(closeLock) {
            pool.close()
            let ids = ArrayList<String>()
            for ((id, _) in subscriptions) {
                ids.add(id)
            }
            for (id in ids) {
                subscriptions.remove(id)
            }
            ownership.clear()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    // ===== 内部 =====

    private func subscriptionOf(subscribedId: String): MQSubscription {
        match (subscriptions.get(subscribedId)) {
            case Some(s) => s
            case None => throw MQServiceException(MQErrorCode.SUBSCRIBE_NOT_EXIST,
                "subscription '${subscribedId}' does not exist")
        }
    }

    private func ensureOpen(): Unit {
        if (closed.load()) {
            throw MQConnectionException("MQClient is closed")
        }
    }

    private func transferOf(node: Int64, message: Message, timeout: Duration): ?Message {
        try {
            pool.clientOf(node).transfer(message, timeout)
        } catch (_: Exception) {
            None<Message>
        }
    }

    /** 候选节点：命中所有权缓存时 owner 优先，其余节点随后兜底。 */
    private func candidateNodes(topic: String): Array<Int64> {
        let all = pool.aliveNodes()
        let preferred = match (ownership.ownersOf(topic)) {
            case Some(owners) => owners
            case None => Array<Int64>()
        }
        let result = ArrayList<Int64>()
        for (node in preferred) {
            if (!result.contains(node)) {
                result.add(node)
            }
        }
        for (node in all) {
            if (!result.contains(node)) {
                result.add(node)
            }
        }
        result.toArray()
    }
}
