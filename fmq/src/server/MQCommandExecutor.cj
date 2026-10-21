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
package fountain::fmq.server

import std.collection.ArrayList
import fountain::f_base.unsafeZeroValue
import fountain::f_log.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.MQServiceException
import fountain::f_net.SocketBuffer
import fountain::f_protocol.default.*
import fountain::fmq.cluster.{BackupReplicator, MetaSyncer}
import fountain::fmq.meta.{MetaApplyResult, MetaStore}
import fountain::fmq.queue.{CursorCatalog, MQMatcher, QueueManager}

/** 无连接的哨兵值：只允许 `refEq` 比较，禁止解引用。 */
internal let EMPTY_SOCKET_BUFFER = unsafeZeroValue<SocketBuffer>()
/**
 * 命令分发：解析 → 校验 → 调服务 → 组装响应。
 *
 * 任何异常都转成 `ERROR(MQResult)`，不向 `f_net` 抛；未知命令/不可解析载荷回 `INTERNAL` 并记 WARN。
 */
protected class MQCommandExecutor {
    private static let log = LoggerFactory.getLogger("fountain::fmq.server.MQCommandExecutor")

    private let store: MetaStore
    private let syncer: MetaSyncer
    private let queues: QueueManager
    private let cursors: CursorCatalog
    private let subscribers: SubscriberRegistry
    private let consume: ConsumeService
    private let backup: BackupReplicator
    private let backupStore: BackupStore
    private let selfIndex: Int64

    protected init(store: MetaStore, syncer: MetaSyncer, queues: QueueManager, cursors: CursorCatalog,
        subscribers: SubscriberRegistry, consume: ConsumeService, backup: BackupReplicator,
        backupStore: BackupStore, selfIndex: Int64) {
        this.store = store
        this.syncer = syncer
        this.queues = queues
        this.cursors = cursors
        this.subscribers = subscribers
        this.consume = consume
        this.backup = backup
        this.backupStore = backupStore
        this.selfIndex = selfIndex
    }

    /** 生产入口：`f_net.Server.start` 直接传方法引用，连接恒非空。 */
    public func execute(buffer: SocketBuffer, request: Message): ?Message {
        dispatch(buffer, request)
    }

    /** 无连接入口：仅供单测与内部调用，订阅不绑定连接。 */
    protected func execute(request: Message): ?Message {
        dispatch(EMPTY_SOCKET_BUFFER, request)
    }

    private func dispatch(buffer: SocketBuffer, request: Message): ?Message {
        try {
            match (request.command) {
                case REGISTER => Some(onRegister(request))
                case DEREGISTER => Some(onDeregister(request))
                case PUBLISH(_) => Some(onPublish(request))
                case SUBSCRIBE => Some(onSubscribe(buffer, request))
                case UNSUBSCRIBE => Some(onUnsubscribe(request))
                case CONSUME(_) => Some(onConsume(request))
                case ACK => Some(onAck(request))
                case _ =>
                    log.warn("unsupported command ${request.command}")
                    Some(MQProtocol.fail(request, MQErrorCode.INTERNAL, "unsupported command"))
            }
        } catch (e: MQServiceException) {
            Some(MQProtocol.fail(request, e.code, e.message))
        } catch (e: Exception) {
            log.warn("execute ${request.command} failed: ${e.message}")
            Some(MQProtocol.fail(request, MQErrorCode.INTERNAL, e.message))
        }
    }

    private func onRegister(request: Message): Message {
        match (MQProtocol.kindOf(request)) {
            case MQPayloadKind.TopicMeta =>
                let meta = MQProtocol.asPayload<MQTopicMeta>(request).getOrThrow {
                    MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQTopicMeta")
                }
                let assignment = syncer.registerTopic(meta)
                queues.openTopic(assignment, selfIndex)
                MQProtocol.respond<MQTopicAssignment>(request, assignment)
            case MQPayloadKind.GroupMeta =>
                let meta = MQProtocol.asPayload<MQSubscribeGroupMeta>(request).getOrThrow {
                    MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQSubscribeGroupMeta")
                }
                syncer.registerGroup(meta)
                MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
            case MQPayloadKind.Internal => onInternal(request)
            case _ =>
                log.warn("REGISTER with unexpected payload")
                MQProtocol.fail(request, MQErrorCode.INTERNAL, "unexpected REGISTER payload")
        }
    }

    /** 内部消息：请求快照 / 主题变更 / 组变更 / 删除 / 指标查询。 */
    private func onInternal(request: Message): Message {
        let envelope = MQProtocol.asInternal(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQInternalMessage")
        }
        if (envelope.kind == MQInternalKind.STATS) {
            let topic = MQProtocol.decodePayload<String>(envelope.payload).getOrThrow {
                MQServiceException(MQErrorCode.INTERNAL, "cannot decode stats topic")
            }
            return MQProtocol.respond<String>(request,
                consume.stats(topic, selfIndex, {name => groupNamesOf(name)}))
        }
        if (envelope.kind != MQInternalKind.META_SYNC) {
            return MQProtocol.fail(request, MQErrorCode.INTERNAL, "unsupported internal kind '${envelope.kind}'")
        }
        // 子载荷类型由编码时的类型 murmur 决定，逐个尝试即可精确分派
        if (let Some(syncRequest) <- MQProtocol.decodePayload<MQMetaSyncRequest>(envelope.payload)) {
            return MQProtocol.respond<MQMetaSnapshot>(request, syncer.snapshotFor(syncRequest.requesterIndex))
        }
        if (let Some(assignment) <- MQProtocol.decodePayload<MQTopicAssignment>(envelope.payload)) {
            let result = syncer.applyRemote(assignment)
            if (result == MetaApplyResult.Applied) {
                queues.openTopic(assignment, selfIndex)
            }
            return MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        }
        if (let Some(meta) <- MQProtocol.decodePayload<MQSubscribeGroupMeta>(envelope.payload)) {
            syncer.applyRemoteGroup(meta)
            return MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        }
        if (let Some(payload) <- MQProtocol.decodePayload<MQDeregisterPayload>(envelope.payload)) {
            syncer.applyRemoteDelete(payload)
            cleanupAfterDelete(payload)
            return MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        }
        MQProtocol.fail(request, MQErrorCode.INTERNAL, "unrecognized metaSync payload")
    }

    private func onDeregister(request: Message): Message {
        let payload = MQProtocol.asPayload<MQDeregisterPayload>(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQDeregisterPayload")
        }
        syncer.deregister(payload)
        cleanupAfterDelete(payload)
        MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
    }

    private func groupNamesOf(topic: String): Array<String> {
        let names = ArrayList<String>()
        for (meta in store.groupsOf(topic)) {
            names.add(meta.subscribeGroup)
        }
        names.toArray()
    }

    private func cleanupAfterDelete(payload: MQDeregisterPayload): Unit {
        if (payload.isTopic()) {
            queues.closeTopic(payload.topic, deleteFiles: true)
            consume.removeTopic(payload.topic)
            subscribers.removeByTopic(payload.topic)
            cursors.removeAllOf(payload.topic)
        } else {
            consume.removeGroup(payload.topic, payload.subscribeGroup)
            subscribers.removeByGroup(payload.topic, payload.subscribeGroup)
            cursors.removeGroup(payload.topic, payload.subscribeGroup)
        }
    }

    private func onPublish(request: Message): Message {
        // 备份推送只落副本，不进入本队列
        if (let Some(internal) <- MQProtocol.asInternal(request)) {
            if (internal.kind == MQInternalKind.BACKUP) {
                let payload = MQProtocol.decodePayload<MQBackupPayload>(internal.payload).getOrThrow {
                    MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQBackupPayload")
                }
                for (i in 0..payload.records.size) {
                    backupStore.append(payload.ownerIndex, payload.topic, payload.queueIndex,
                        payload.records[i].copyBytes())
                }
                return MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
            }
            return MQProtocol.fail(request, MQErrorCode.INTERNAL, "unsupported internal kind '${internal.kind}'")
        }
        let record = MQProtocol.asRecord(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "publish payload is not a record")
        }
        let topic = MQMessageRecord.topic(record).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode record topic")
        }
        if (store.topicOf(topic).isNone()) {
            return MQProtocol.fail(request, MQErrorCode.TOPIC_NOT_EXIST, "topic '${topic}' does not exist")
        }
        // 有非空 filter 的活跃订阅时，BODY 必须可评估；否则发布即会静默丢消息，直接拒绝且不落盘
        if (!bodyIsEvaluable(topic, record)) {
            return MQProtocol.fail(request, MQErrorCode.FILTER_UNSUPPORTED_BODY,
                MQErrorCode.messageOf(MQErrorCode.FILTER_UNSUPPORTED_BODY))
        }
        match (queues.pickQueue(topic)) {
            case None => MQProtocol.fail(request, MQErrorCode.NOT_OWNER, "this node owns no queue of '${topic}'")
            case Some((queueIndex, log)) =>
                let position = log.append(record)
                backup.record(topic, queueIndex, position, record)
                MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        }
    }

    /**
     * 该主题下是否有活跃订阅的非空 filter 无法评估这条记录的 BODY。
     *
     * 空 filter 不需要服务端解码 BODY；只有「filter 非空 + BODY 解不出」才是无法评估。
     * 返回 `false` 时发布必须失败且不落盘。
     */
    private func bodyIsEvaluable(topic: String, record: Array<Byte>): Bool {
        for (info in subscribers.byTopicOf(topic)) {
            if (info.filter.path.isEmpty()) {
                continue
            }
            match (MQMatcher.matches(info.view(), record)) {
                case Unsupported => return false
                case _ => ()
            }
        }
        true
    }

    private func onSubscribe(buffer: SocketBuffer, request: Message): Message {
        let payload = MQProtocol.asPayload<MQSubscribePayload>(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQSubscribePayload")
        }
        if (!MQTopic.isValid(payload.topic)) {
            return MQProtocol.fail(request, MQErrorCode.INVALID_TOPIC, "invalid topic '${payload.topic}'")
        }
        if (store.topicOf(payload.topic).isNone()) {
            return MQProtocol.fail(request, MQErrorCode.TOPIC_NOT_EXIST,
                "topic '${payload.topic}' does not exist")
        }
        if (!store.groupExists(payload.topic, payload.subscribeGroup)) {
            return MQProtocol.fail(request, MQErrorCode.GROUP_NOT_EXIST,
                "subscribe group '${payload.subscribeGroup}' does not exist")
        }
        if (queues.localQueues(payload.topic).size == 0) {
            return MQProtocol.fail(request, MQErrorCode.NOT_OWNER,
                "this node owns no queue of '${payload.topic}'")
        }
        let info = MQSubscriptionInfo(payload.subscribedId, payload.topic, payload.subscribeGroup, payload.tags,
            MQFilter.compile(payload.filter), payload.autoAck, buffer)
        subscribers.register(info)
        MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
    }

    private func onUnsubscribe(request: Message): Message {
        let payload = MQProtocol.asPayload<MQUnsubscribePayload>(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQUnsubscribePayload")
        }
        match (subscribers.of(payload.subscribedId)) {
            case None =>
                MQProtocol.fail(request, MQErrorCode.SUBSCRIBE_NOT_EXIST,
                    "subscription '${payload.subscribedId}' does not exist")
            case Some(info) =>
                consume.releaseSubscription(info)
                subscribers.unregister(payload.subscribedId)
                MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        }
    }

    private func onConsume(request: Message): Message {
        let payload = MQProtocol.asPayload<MQConsumePayload>(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQConsumePayload")
        }
        let info = match (subscribers.of(payload.subscribedId)) {
            case Some(value) => value
            case None => return MQProtocol.fail(request, MQErrorCode.SUBSCRIBE_NOT_EXIST,
                "subscription '${payload.subscribedId}' does not exist")
        }
        match (consume.consume(info)) {
            case Some(result) => MQProtocol.respond<MQConsumeResult>(request, result)
            case None => MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult())
        }
    }

    private func onAck(request: Message): Message {
        let payload = MQProtocol.asPayload<MQAckPayload>(request).getOrThrow {
            MQServiceException(MQErrorCode.INTERNAL, "cannot decode MQAckPayload")
        }
        let info = match (subscribers.of(payload.subscribedId)) {
            case Some(value) => value
            case None => return MQProtocol.fail(request, MQErrorCode.SUBSCRIBE_NOT_EXIST,
                "subscription '${payload.subscribedId}' does not exist")
        }
        let result = consume.ack(info, payload)
        MQProtocol.respond<MQResult>(request, result)
    }
}
