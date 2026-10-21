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
package fountain::fmq.cluster

import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.Mutex
import std.time.DateTime
import fountain::f_log.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.{MQSubscribeGroupMeta, MQTopicMeta}
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.MQServiceException
import fountain::f_protocol.default.Message
import fountain::fmq.meta.{MQAssignment, MetaApplyResult, MetaStore}

/**
 * 元数据复制：本地落盘 → 广播 → 回响应。
 *
 * 冲突按「先到者优先 + WARN」处理；广播失败只记 WARN，peer 恢复后由启动期全量同步补齐。
 */
protected class MetaSyncer {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.MetaSyncer")
    private static let SYNC_TIMEOUT_MULTIPLIER = 5

    private static let PENDING_TTL_MS: Int64 = 5 * 60 * 1000
    private static let MAX_PENDING: Int64 = 1024

    private let store: MetaStore
    private let transport: MQNodeTransport
    /** 主题未到达的组（有界 + TTL），主题落地后自动应用（A36） */
    private let pendingLock = Mutex()
    private let pendingGroups = HashMap<String, PendingGroup>()

    protected init(store: MetaStore, transport: MQNodeTransport) {
        this.store = store
        this.transport = transport
    }

    /** 注册主题：检查/分配/写盘全在 store 的同一临界区，只有落盘成功才广播（A28）。 */
    protected func registerTopic(meta: MQTopicMeta): MQTopicAssignment {
        if (!MQTopic.isValid(meta.topic)) {
            throw MQServiceException(MQErrorCode.INVALID_TOPIC, "invalid topic '${meta.topic}'")
        }
        if (meta.queueNum < 1) {
            throw MQServiceException(MQErrorCode.INVALID_TOPIC, "queueNum must be at least 1")
        }
        if (meta.delayingMs < 0) {
            throw MQServiceException(MQErrorCode.INVALID_TOPIC, "delaying must not be negative")
        }
        let nodeCount = transport.nodeCount
        if (nodeCount < 1) {
            throw MQServiceException(MQErrorCode.INTERNAL, "no node in cluster")
        }
        let (result, assignment) = store.registerTopic(meta, nodeCount)
        match (result) {
            case MetaApplyResult.Applied =>
                let persisted = assignment.getOrThrow()
                broadcastTopic(persisted)
                persisted
            case MetaApplyResult.Duplicated =>
                throw MQServiceException(MQErrorCode.TOPIC_ALREADY_EXIST, "topic '${meta.topic}' already exists")
            case _ =>
                throw MQServiceException(MQErrorCode.INTERNAL, "cannot register topic '${meta.topic}'")
        }
    }

    protected func registerGroup(meta: MQSubscribeGroupMeta): MQResult {
        match (store.registerGroup(meta)) {
            case MetaApplyResult.Applied => ()
            case MetaApplyResult.TopicMissing =>
                throw MQServiceException(MQErrorCode.TOPIC_NOT_EXIST, "topic '${meta.topic}' does not exist")
            case MetaApplyResult.Duplicated =>
                throw MQServiceException(MQErrorCode.GROUP_ALREADY_EXIST,
                    "subscribe group '${meta.subscribeGroup}' already exists on '${meta.topic}'")
            case _ =>
                throw MQServiceException(MQErrorCode.INTERNAL, "cannot register group '${meta.subscribeGroup}'")
        }
        // 广播落盘后的对象（revision/origin 以盘上为准）
        match (store.groupsOf(meta.topic)) {
            case list =>
                for (group in list) {
                    if (group.subscribeGroup == meta.subscribeGroup) {
                        broadcastGroup(group)
                        break
                    }
                }
        }
        MQResult(0, "ok")
    }

    /** 注销：先写墓碑 + 删本地元数据，再广播墓碑（删除必须能传播，见 A25）。 */
    protected func deregister(payload: MQDeregisterPayload): MQResult {
        let tombstone = if (payload.isTopic()) {
            match (store.removeTopic(payload.topic)) {
                case Some(value) => value
                case None => throw MQServiceException(MQErrorCode.TOPIC_NOT_EXIST,
                    "topic '${payload.topic}' does not exist")
            }
        } else {
            match (store.removeGroup(payload.topic, payload.subscribeGroup)) {
                case Some(value) => value
                case None => throw MQServiceException(MQErrorCode.GROUP_NOT_EXIST,
                    "subscribe group '${payload.subscribeGroup}' does not exist")
            }
        }
        broadcastTombstone(tombstone)
        MQResult(0, "ok")
    }

    /** 收到 peer 的 metaSync 请求 → 返回全量快照。 */
    protected func snapshotFor(requesterIndex: Int64): MQMetaSnapshot {
        store.snapshot()
    }

    /** 启动期：向第一个可达 peer 拉全量快照并合并。 */
    protected func syncFromPeers(): Unit {
        let nodeCount = transport.nodeCount
        if (nodeCount <= 1) {
            return
        }
        for (offset in 1..nodeCount) {
            let peer = (transport.selfIndex + offset) % nodeCount
            let response = transport.send(peer, MQProtocol.metaSync(MQMetaSyncRequest(transport.selfIndex)))
            if (let Some(message) <- response) {
                if (let Some(snapshot) <- MQProtocol.asPayload<MQMetaSnapshot>(message)) {
                    mergeSnapshot(snapshot)
                    return
                }
            }
        }
        log.warn("no peer reachable during startup sync, using local metadata")
    }

    protected func applyRemote(assignment: MQTopicAssignment): MetaApplyResult {
        let nodeCount = transport.nodeCount
        let nextStart = if (nodeCount < 1) {
            assignment.startNodeIndex
        } else {
            MQAssignment.nextStart(assignment.startNodeIndex, assignment.queueNum, nodeCount)
        }
        // 指针只增不减：乱序到达的旧分配不能把轮转指针拉回去（A33）
        let current = store.nextStartNode
        let persisted = if (nextStart > current) { nextStart } else { current }
        let result = store.applyTopic(assignment, nextStart: persisted)
        if (result == MetaApplyResult.Applied) {
            flushPendingGroups(assignment.topic)
        }
        result
    }

    protected func applyRemoteGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        let result = store.applyGroup(meta)
        if (result == MetaApplyResult.TopicMissing) {
            addPendingGroup(meta)
        }
        result
    }

    /** 主题落地后重试待应用的组。 */
    private func flushPendingGroups(topic: String): Unit {
        let prefix = "${topic}\u{0}"
        let candidates = ArrayList<String>()
        synchronized(pendingLock) {
            for ((key, _) in pendingGroups) {
                if (key.startsWith(prefix)) {
                    candidates.add(key)
                }
            }
        }
        for (key in candidates) {
            let pendingMeta = synchronized(pendingLock) {
                match (pendingGroups.get(key)) {
                    case Some(value) => Some(value.meta)
                    case None => None<MQSubscribeGroupMeta>
                }
            }
            match (pendingMeta) {
                case Some(meta) =>
                    if (store.applyGroup(meta) == MetaApplyResult.Applied) {
                        synchronized(pendingLock) {
                            pendingGroups.remove(key)
                        }
                    }
                case None => ()
            }
        }
    }

    private func addPendingGroup(meta: MQSubscribeGroupMeta): Unit {
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let key = "${meta.topic}\u{0}${meta.subscribeGroup}"
        synchronized(pendingLock) {
            // 先淘汰过期项；队列有界，满了就拒绝并 WARN
            let expired = ArrayList<String>()
            for ((k, value) in pendingGroups) {
                if (now - value.addedMs > PENDING_TTL_MS) {
                    expired.add(k)
                }
            }
            for (k in expired) {
                pendingGroups.remove(k)
            }
            if (pendingGroups.get(key).isSome()) {
                return
            }
            if (pendingGroups.size >= MAX_PENDING) {
                log.warn("pending group queue is full (${MAX_PENDING}), dropping group '${meta.subscribeGroup}'")
                return
            }
            pendingGroups.add(key, PendingGroup(meta, now))
        }
    }

    /** 旧版 peer 的删除广播（无墓碑）：本地补一条墓碑，避免二次复活。 */
    protected func applyRemoteDelete(payload: MQDeregisterPayload): Bool {
        let kind = if (payload.isTopic()) {
            MQMetaTombstone.KIND_TOPIC
        } else {
            MQMetaTombstone.KIND_GROUP
        }
        let tombstone = MQMetaTombstone(kind, payload.topic, payload.subscribeGroup, store.nextRevision(),
            transport.selfIndex, DateTime.now().toUnixTimeStamp().toMilliseconds())
        store.applyTombstone(tombstone) == MetaApplyResult.Applied
    }

    /** 收到 peer 的墓碑广播。 */
    protected func applyRemoteTombstone(tombstone: MQMetaTombstone): MetaApplyResult {
        store.applyTombstone(tombstone)
    }

    /**
     * 合并全量快照：应用条目与墓碑 → 本地更旧且快照缺失的条目视为删除 → 指针只进不退。
     *
     * 墓碑让「离线节点重启后复活已删主题/组」不再发生（A25）；缺失扫描是墓碑被 GC 后的兜底。
     */
    private func mergeSnapshot(snapshot: MQMetaSnapshot): Unit {
        for (tombstone in snapshot.tombstones) {
            store.applyTombstone(tombstone)
        }
        let topicNames = HashSet<String>()
        for (assignment in snapshot.topics) {
            topicNames.add(assignment.topic)
            store.applyTopic(assignment)
        }
        let groupKeys = HashSet<String>()
        for (meta in snapshot.groups) {
            groupKeys.add("${meta.topic}\u{0}${meta.subscribeGroup}")
            store.applyGroup(meta)
        }
        let tombstoneKeys = HashSet<String>()
        for (tombstone in snapshot.tombstones) {
            tombstoneKeys.add(tombstone.key())
        }
        // 兜底：快照里没有、本地更旧的条目视为已删除。只在快照带版本时执行，
        // 避免与「全是 0 版本的旧数据」互相清空。
        if (snapshot.revision > 0) {
            for (assignment in store.topics()) {
                if (!topicNames.contains(assignment.topic) &&
                    !tombstoneKeys.contains("${MQMetaTombstone.KIND_TOPIC}\u{0}${assignment.topic}") &&
                    assignment.revision <= snapshot.revision) {
                    log.warn("topic '${assignment.topic}' is missing from the peer snapshot, dropping it")
                    store.dropTopicLocally(assignment.topic)
                }
            }
            for (meta in store.allGroups()) {
                if (!groupKeys.contains("${meta.topic}\u{0}${meta.subscribeGroup}") &&
                    !tombstoneKeys.contains("${MQMetaTombstone.KIND_GROUP}\u{0}${meta.topic}\u{0}${meta.subscribeGroup}") &&
                    meta.revision <= snapshot.revision) {
                    log.warn("group '${meta.subscribeGroup}' of '${meta.topic}' is missing from the peer snapshot, dropping it")
                    store.dropGroupLocally(meta.topic, meta.subscribeGroup)
                }
            }
        }
        // 轮转指针只增不减，乱序快照不会让分配回退
        if (snapshot.nextStartNode > store.nextStartNode) {
            store.advanceNextStart(snapshot.nextStartNode)
        }
    }

    private func broadcastTopic(assignment: MQTopicAssignment): Unit {
        broadcast(MQProtocol.metaSync(assignment))
    }

    private func broadcastGroup(meta: MQSubscribeGroupMeta): Unit {
        broadcast(MQProtocol.metaSync(meta))
    }

    private func broadcastTombstone(tombstone: MQMetaTombstone): Unit {
        broadcast(MQProtocol.metaSync(tombstone))
    }

    private func broadcast(message: Message): Unit {
        let nodeCount = transport.nodeCount
        for (index in 0..nodeCount) {
            if (index == transport.selfIndex) {
                continue
            }
            if (transport.send(index, message).isNone()) {
                log.warn("metadata broadcast to node ${index} failed, peer will catch up on startup")
            }
        }
    }
}

/** 等待主题到达的组。 */
private class PendingGroup {
    let meta: MQSubscribeGroupMeta
    let addedMs: Int64

    init(meta: MQSubscribeGroupMeta, addedMs: Int64) {
        this.meta = meta
        this.addedMs = addedMs
    }
}
