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
import fountain::f_log.*
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
    private static let log = LoggerFactory.getLogger("fountain::f_mq.client.MQClient")
    private static let PUBLISH_TIMEOUT = Duration.second * 5
    private static let SUBSCRIBE_TIMEOUT = Duration.second * 5
    private static let CONSUME_TIMEOUT = Duration.second
    private static let ACK_TIMEOUT = Duration.second * 5
    private static let CONSUME_POLL_INTERVAL = Duration.millisecond * 200

    private let pool: MQNodePool
    private let ownership: MQOwnershipCache
    private let subscriptions = ConcurrentHashMap<String, MQSubscription>()
    private let retired = MQRetiredSubscriptions()
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
        if (!MQTags.isValid(tags)) {
            throw MQException("invalid tags on topic '${topic}'")
        }
        // 用 UTC 生成 id：帧里的时间戳往返后按 UTC 表示，记录中的 MESSAGE_ID 才能与解码后的帧 id 逐字一致。
        // hostId 显式取自配置：它参与 MessageID 的相等/哈希（跨机器 pid/tid 会重复），
        // 也是内存 id 与记录里 MESSAGE_ID 共同的节点维度，不能靠默认值兜底
        let id = MessageID(time: DateTime.nowUTC(), hostId: ProtocolConfig.getProtocolHostId())
        let record = MQMessageRecord.encode(topic, tags, id.toString(), body)
        var sawNotOwner = false
        var lastConnectionError: ?Exception = None
        let candidates = candidateNodes(topic)
        for (node in candidates) {
            match (transferOf(node, MQProtocol.publish(record, id: id), PUBLISH_TIMEOUT)) {
                case TransferOutcome.Response(msg) =>
                    let result = MQProtocol.asResult(msg)
                    if (result.code == MQErrorCode.OK) {
                        // 记下实际接受发布的节点，后续发布优先复用它
                        ownership.put(topic, [node])
                        return
                    }
                    if (result.code == MQErrorCode.NOT_OWNER) {
                        // 缓存可能过期：失效后继续尝试下一个节点
                        ownership.invalidate(topic)
                        sawNotOwner = true
                        continue
                    }
                    throw MQServiceException(result.code, result.message)
                case TransferOutcome.Timeout =>
                    lastConnectionError = MQConnectionException("publish to node ${node} timed out")
                case TransferOutcome.Rejected(e) =>
                    lastConnectionError = e
            }
        }
        // 全部 NOT_OWNER 是服务端给出的确定答案，不能报成「连不上」（A18）；混有连接失败时才按连接问题处理
        if (sawNotOwner && lastConnectionError.isNone()) {
            throw MQServiceException(MQErrorCode.NOT_OWNER, MQErrorCode.messageOf(MQErrorCode.NOT_OWNER))
        }
        log.error("publish to topic '${topic}' failed on nodes ${nodeList(candidates)}")
        match (lastConnectionError) {
            case Some(e) => throw MQConnectionException("cannot publish to any node of topic '${topic}'", e)
            case None => throw MQConnectionException("cannot publish to any node of topic '${topic}'")
        }
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
        if (!MQGroup.isValid(subscribeGroup)) {
            throw MQException("invalid subscribe group '${subscribeGroup}'")
        }
        if (!MQTags.isValid(tags)) {
            throw MQException("invalid tags on topic '${topic}'")
        }
        // 非法表达式在本地失败，不发请求；编译结果只用于校验，不随订阅保存（R1-G2）
        MQFilter.compile(filter)
        let subscribedId = UUID.random().toString()
        let payload = MQSubscribePayload(subscribedId, topic, subscribeGroup, tags, filter, autoAck)
        let accepted = ArrayList<Int64>()
        var fatal: ?MQServiceException = None
        var connectionFailures = 0
        for (node in 0..pool.size) {
            match (transferOf(node, MQProtocol.subscribe(payload), SUBSCRIBE_TIMEOUT)) {
                case TransferOutcome.Response(msg) =>
                    let result = MQProtocol.asResult(msg)
                    if (result.code == MQErrorCode.OK) {
                        accepted.add(node)
                    } else if (result.code == MQErrorCode.NOT_OWNER) {
                        // 该节点没有此主题的队列，跳过
                    } else {
                        fatal = Some(MQServiceException(result.code, result.message))
                    }
                case _ => connectionFailures++
            }
            if (fatal.isSome()) {
                break
            }
        }
        if (let Some(error) <- fatal) {
            let failedNodes = rollback(subscribedId, topic, accepted)
            let suffix = if (failedNodes.size == 0) {
                ""
            } else {
                "；回滚失败的节点：${String.join(failedNodes, delimiter: ",")}"
            }
            throw MQServiceException(error.code, error.message + suffix)
        }
        if (accepted.size == 0) {
            if (connectionFailures == pool.size) {
                throw MQConnectionException("all nodes are unreachable for topic '${topic}'")
            }
            throw MQConnectionException("no node owns topic '${topic}'")
        }
        let owners = accepted.toArray()
        subscriptions.add(subscribedId, MQSubscription(subscribedId, topic, subscribeGroup, autoAck, owners))
        ownership.put(topic, owners)
        subscribedId
    }

    /** 回滚已接受的节点；返回回滚失败的节点描述（调用方把它拼进异常文案，A15）。 */
    private func rollback(subscribedId: String, topic: String, accepted: ArrayList<Int64>): Array<String> {
        if (accepted.size == 0) {
            return []
        }
        let payload = MQUnsubscribePayload(subscribedId)
        let failed = ArrayList<String>()
        for (node in accepted) {
            match (transferOf(node, MQProtocol.unsubscribe(payload), ACK_TIMEOUT)) {
                case TransferOutcome.Response(msg) =>
                    if (msg.command == Command.ERROR) {
                        let result = MQProtocol.asResult(msg)
                        if (result.code != MQErrorCode.SUBSCRIBE_NOT_EXIST) {
                            failed.add("${node}(code ${result.code})")
                        }
                    }
                case TransferOutcome.Timeout => failed.add("${node}(timeout)")
                case TransferOutcome.Rejected(e) => failed.add("${node}(${e.message})")
            }
        }
        if (failed.size > 0) {
            log.error("rollback of subscription '${subscribedId}' (topic '${topic}') failed on nodes: " +
                "${String.join(failed.toArray(), delimiter: ",")}")
        }
        failed.toArray()
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
            var responded = 0
            var lastConnectionError: ?Exception = None
            for (i in 0..sub.owners.size) {
                let node = sub.owners[(start + i) % sub.owners.size]
                match (transferOf(node, MQProtocol.consume(MQConsumePayload(subscribedId)), CONSUME_TIMEOUT)) {
                    case TransferOutcome.Response(msg) =>
                        responded++
                        if (msg.command == Command.ERROR) {
                            let result = MQProtocol.asResult(msg)
                            // SUBSCRIBE_NOT_EXIST 与其它服务端错误都不能再静默空转（A12/A16）
                            throw MQServiceException(result.code, result.message)
                        }
                        match (MQProtocol.asConsumeResult(msg)) {
                            case Some(result) =>
                                if (result.record.isEmpty()) {
                                    continue
                                }
                                match (MQMessageRecord.decode(result.record.copyBytes())) {
                                    case Some(content) =>
                                        if (!sub.autoAck) {
                                            let key = MQSubscription.keyOf(result.queueIndex,
                                                result.segmentedIndex, result.segmentedOffset)
                                            // 原子认领：服务端重投窗口内同一位置只允许一个线程取走（A20）
                                            match (sub.deliveries.addIfAbsent(key, node)) {
                                                case Some(_) => continue
                                                case None => ()
                                            }
                                        }
                                        return content.toMessage(result.queueIndex, result.segmentedIndex,
                                            result.segmentedOffset)
                                    case None =>
                                        // 非空记录解不出来：不能当成「没有消息」继续轮询（A16）
                                        log.error("cannot decode record of subscription ${subscribedId} " +
                                            "(topic ${sub.topic}, group ${groupOf(sub)}) at " +
                                            "${result.queueIndex}:${result.segmentedIndex}:${result.segmentedOffset} " +
                                            "(${result.record.size()} bytes)")
                                        throw MQServiceException(MQErrorCode.INTERNAL,
                                            "cannot decode consume result of subscription ${subscribedId} " +
                                            "(topic ${sub.topic}) at ${result.queueIndex}:" +
                                            "${result.segmentedIndex}:${result.segmentedOffset}")
                                }
                            case None =>
                                log.error("consume response of ${subscribedId} (topic ${sub.topic}) " +
                                    "is not MQConsumeResult")
                                throw MQServiceException(MQErrorCode.INTERNAL,
                                    "consume response of subscription ${subscribedId} (topic ${sub.topic}) " +
                                    "is not MQConsumeResult")
                        }
                    case TransferOutcome.Timeout =>
                        lastConnectionError = MQConnectionException("consume on node ${node} timed out")
                    case TransferOutcome.Rejected(e) =>
                        lastConnectionError = e
                }
            }
            if (responded == 0) {
                // 本轮全部节点不可达：明确报错，而不是永久空转（A12）
                // 文案带节点下标：调用方直接上抛或落业务日志时也能看到是哪些节点失败（A16）
                let tried = nodeList(sub.owners)
                log.error("consume on subscription '${subscribedId}' (topic '${sub.topic}') failed: " +
                    "nodes ${tried} unreachable")
                match (lastConnectionError) {
                    case Some(e) =>
                        throw MQConnectionException(
                            "all owner nodes of subscription '${subscribedId}' (topic '${sub.topic}') " +
                            "are unreachable (tried nodes ${tried})", e)
                    case None =>
                        throw MQConnectionException(
                            "all owner nodes of subscription '${subscribedId}' (topic '${sub.topic}') " +
                            "are unreachable (tried nodes ${tried})")
                }
            }
            sleep(CONSUME_POLL_INTERVAL)
        }
        // 循环内只会 return 或 throw；这一行只为让编译器确认返回类型
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
        let key = MQSubscription.keyOf(queueIndex, segmentedIndex, segmentedOffset)
        match (sub.deliveries.get(key)) {
            case Some(node) =>
                // 发送成功后才删映射：失败时保留，重试仍能命中同一节点（A13）
                match (transferOf(node, MQProtocol.ack(payload), ACK_TIMEOUT)) {
                    case TransferOutcome.Response(msg) =>
                        if (msg.command == Command.ERROR) {
                            let result = MQProtocol.asResult(msg)
                            if (result.code != MQErrorCode.ACK_UNKNOWN) {
                                throw MQServiceException(result.code, result.message)
                            }
                        }
                        sub.deliveries.remove(key)
                    case TransferOutcome.Timeout =>
                        log.error("ack of subscription '${subscribedId}' (topic '${sub.topic}') at ${key} " +
                            "timed out on node ${node}")
                        throw MQConnectionException("ack to node ${node} timed out")
                    case TransferOutcome.Rejected(e) =>
                        log.error("ack of subscription '${subscribedId}' (topic '${sub.topic}') at ${key} " +
                            "failed on node ${node}: ${e.message}")
                        throw MQConnectionException("cannot ack position ${key} on node ${node}", e)
                }
            case None =>
                // 未知投递来源（autoAck / 重启后重投）：广播，任一节点接受即算成功
                var accepted = false
                var lastConnectionError: ?Exception = None
                for (node in sub.owners) {
                    match (transferOf(node, MQProtocol.ack(payload), ACK_TIMEOUT)) {
                        case TransferOutcome.Response(msg) =>
                            if (msg.command == Command.ERROR) {
                                let result = MQProtocol.asResult(msg)
                                if (result.code == MQErrorCode.OK || result.code == MQErrorCode.ACK_UNKNOWN) {
                                    accepted = true
                                } else {
                                    throw MQServiceException(result.code, result.message)
                                }
                            } else {
                                accepted = true
                            }
                        case TransferOutcome.Timeout =>
                            lastConnectionError = MQConnectionException("ack to node ${node} timed out")
                        case TransferOutcome.Rejected(e) =>
                            lastConnectionError = e
                    }
                }
                if (!accepted) {
                    log.error("ack of subscription '${subscribedId}' (topic '${sub.topic}') at ${key} " +
                        "failed on nodes ${nodeList(sub.owners)}")
                    match (lastConnectionError) {
                        case Some(e) =>
                            throw MQConnectionException("cannot ack position ${key} on any node", e)
                        case None =>
                            throw MQConnectionException("cannot ack position ${key} on any node")
                    }
                }
        }
    }

    // ===== 退订与生命周期 =====

    /**
     * 退订：向该订阅的所有 owner 发送 `UNSUBSCRIBE` 并删除本地订阅。
     *
     * 幂等：同一 id 重复退订返回成功且不再发请求（本地已无该订阅）；
     * 服务端回 `SUBSCRIBE_NOT_EXIST` 视为成功；从未订阅过的 id 抛异常且不发请求。
     * 部分节点失败时保留本地订阅，调用方可重试。
     */
    public func unsubscribe(subscribedId: String): Unit {
        ensureOpen()
        let sub = match (subscriptions.get(subscribedId)) {
            case Some(s) => s
            case None =>
                // 已退订 → 成功空操作；从未订阅 → 未知 id（R5-4）
                if (retired.contains(subscribedId)) {
                    return
                }
                throw MQServiceException(MQErrorCode.SUBSCRIBE_NOT_EXIST,
                    "subscription '${subscribedId}' does not exist")
        }
        let payload = MQUnsubscribePayload(subscribedId)
        let failed = ArrayList<String>()
        for (node in sub.owners) {
            match (transferOf(node, MQProtocol.unsubscribe(payload), ACK_TIMEOUT)) {
                case TransferOutcome.Response(msg) =>
                    if (msg.command == Command.ERROR) {
                        let result = MQProtocol.asResult(msg)
                        // 服务端已经没有该订阅：视为成功
                        if (result.code != MQErrorCode.SUBSCRIBE_NOT_EXIST) {
                            failed.add("${node}(code ${result.code})")
                        }
                    }
                case TransferOutcome.Timeout => failed.add("${node}(timeout)")
                case TransferOutcome.Rejected(e) => failed.add("${node}(${e.message})")
            }
        }
        if (failed.size > 0) {
            // 本地订阅保留，调用方可重试（A14）
            log.error("unsubscribe '${subscribedId}' (topic '${sub.topic}', group '${groupOf(sub)}') " +
                "failed on nodes: ${String.join(failed.toArray(), delimiter: ",")}")
            throw MQConnectionException(
                "unsubscribe '${subscribedId}' (topic '${sub.topic}') failed on nodes: " +
                "${String.join(failed.toArray(), delimiter: ",")}")
        }
        subscriptions.remove(subscribedId)
        retired.add(subscribedId)
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

    /**
     * 向单节点发一次请求。
     *
     * 超时与连接失败都在这里记 WARN（含节点下标与地址）：全 owner 不可达时排障要能定位到具体节点（A16）。
     */
    private func transferOf(node: Int64, message: Message, timeout: Duration): TransferOutcome {
        let address = pool.hostOf(node)
        try {
            match (pool.clientOf(node).transfer(message, timeout)) {
                case Some(response) => TransferOutcome.Response(response)
                case None =>
                    log.warn("request to node ${node} (${address}) timed out after ${timeout}")
                    TransferOutcome.Timeout
            }
        } catch (e: Exception) {
            log.warn("request to node ${node} (${address}) failed: ${e.message}")
            TransferOutcome.Rejected(e)
        }
    }

    /** 订阅组名的日志表示：默认组显示为 `<default>`。 */
    private static func groupOf(sub: MQSubscription): String {
        if (sub.subscribeGroup.isEmpty()) {
            "<default>"
        } else {
            sub.subscribeGroup
        }
    }

    /** 节点下标的可读列表，用于日志与异常文案。 */
    private static func nodeList(nodes: Array<Int64>): String {
        let buf = StringBuilder()
        for (i in 0..nodes.size) {
            if (i > 0) {
                buf.append(",")
            }
            buf.append(nodes[i].toString())
        }
        "[${buf.toString()}]"
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

/**
 * 一次请求的三种结局。
 *
 * 旧实现把「服务端回包」「超时」「连不上」都折成 `None`，导致调用方
 * 无法区分「服务错误」与「连接失败」（A12/A18）。
 */
internal enum TransferOutcome {
    | Response(Message)
    | Timeout
    | Rejected(Exception)
}
