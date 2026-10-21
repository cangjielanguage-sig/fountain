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
import std.sync.{Mutex, Timer}
import std.time.DateTime
import fountain::f_log.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.{MQSubscribeGroupMeta, MQTopicMeta}
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.MQServiceException
import fountain::f_protocol.default.{Command, Message}
import fountain::fmq.meta.{MQAssignment, MetaApplyResult, MetaStore}

/**
 * 元数据复制：本地落盘 → 广播 → 回响应。
 *
 * 冲突按「先到者优先 + WARN」处理；广播失败进入待补偿集合并记 WARN，由反熵定时同步补齐（A31）。
 */
protected class MetaSyncer <: Resource {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.MetaSyncer")
    private static let PENDING_TTL_MS: Int64 = 5 * 60 * 1000
    private static let MAX_PENDING: Int64 = 1024

    private let store: MetaStore
    private let transport: MQNodeTransport
    /** 主题未到达的组（有界 + TTL），主题落地后自动应用（A36） */
    private let pendingLock = Mutex()
    private let pendingGroups = HashMap<String, PendingGroup>()
    /** 广播失败的 peer：反熵同步成功后清空（A31） */
    private let pendingPeersLock = Mutex()
    private let pendingPeers = HashSet<Int64>()
    private var antiEntropyTimer: ?Timer = None
    private var closed = false
    /** 主题落地后打开本机队列（A29） */
    private var topicAppliedCallback: ?(String) -> Unit = None
    /** 删除生效后清理本机队列/游标/订阅/计数器（A25 的对端侧） */
    private var deletedCallback: ?(MQDeregisterPayload) -> Unit = None

    protected init(store: MetaStore, transport: MQNodeTransport) {
        this.store = store
        this.transport = transport
    }

    /** 主题落地回调；服务装配里接到 `QueueManager.openTopic`。 */
    protected mut prop onTopicApplied: ?(String) -> Unit {
        get() {
            topicAppliedCallback
        }
        set(value) {
            topicAppliedCallback = value
        }
    }

    /** 删除生效回调；服务装配里接到 `MQCommandExecutor.cleanupAfterDelete`。 */
    protected mut prop onDeleted: ?(MQDeregisterPayload) -> Unit {
        get() {
            deletedCallback
        }
        set(value) {
            deletedCallback = value
        }
    }

    /**
     * 启动反熵：每个间隔向 peer 拉一次全量快照，补齐广播丢失的变更。
     *
     * 已启动过则忽略，保证幂等。
     */
    protected func startAntiEntropy(interval: Duration): Unit {
        if (antiEntropyTimer.isSome()) {
            return
        }
        antiEntropyTimer = Some(Timer.repeat(interval, interval, {=> antiEntropyOnce()}))
    }

    /** 单个反熵周期：异常不得让定时器失效。 */
    protected func antiEntropyOnce(): Unit {
        try {
            syncFromPeers()
        } catch (e: Exception) {
            log.warn("anti-entropy sync failed: ${e.message}")
        }
    }

    /** 待补偿 peer 数量（用例断言）。 */
    protected func pendingPeerCount(): Int64 {
        synchronized(pendingPeersLock) {
            Int64(pendingPeers.size)
        }
    }

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        closed = true
        match (antiEntropyTimer) {
            case Some(timer) =>
                timer.cancel()
                antiEntropyTimer = None
            case None => ()
        }
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
                notifyTopicApplied(persisted.topic)
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
            case MetaApplyResult.Invalid =>
                throw MQServiceException(MQErrorCode.INVALID_GROUP,
                    "invalid subscribe group '${meta.subscribeGroup}'")
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
        let tombstones = if (payload.isTopic()) {
            let removed = store.removeTopic(payload.topic)
            if (removed.size == 0) {
                throw MQServiceException(MQErrorCode.TOPIC_NOT_EXIST,
                    "topic '${payload.topic}' does not exist")
            }
            removed
        } else {
            match (store.removeGroup(payload.topic, payload.subscribeGroup)) {
                case Some(value) => [value]
                case None => throw MQServiceException(MQErrorCode.GROUP_NOT_EXIST,
                    "subscribe group '${payload.subscribeGroup}' does not exist")
            }
        }
        // 主题墓碑之后是该主题各组墓碑，逐条广播
        for (tombstone in tombstones) {
            broadcastTombstone(tombstone)
        }
        MQResult(0, "ok")
    }

    /** 收到 peer 的 metaSync 请求 → 返回全量快照。 */
    protected func snapshotFor(): MQMetaSnapshot {
        store.snapshot()
    }

    /**
     * 向 peer 拉全量快照并合并（启动同步与反熵共用）。
     *
     * 失败原因分开记：无可用 peer / 已知死亡被跳过 / 连接失败 / 服务端返回错误 / 载荷不可解码。
     */
    protected func syncFromPeers(): Unit {
        let nodeCount = transport.nodeCount
        if (nodeCount <= 1) {
            return
        }
        var attempted = 0i64
        var skipped = 0i64
        // 三趟：未知 → 存活 → 已知死亡。未知节点优先探测（可能刚恢复、也可能从未联系过），
        // 存活节点次之，已知死亡最后仍要试——直接跳过会让它在恢复后永远拿不到同步（A40）。
        for (pass in 0..3) {
            for (offset in 1..nodeCount) {
            let peer = (transport.selfIndex + offset) % nodeCount
            let knownDead = transport.isKnownDead(peer)
            let tier = if (knownDead) {
                2
            } else if (transport.isAlive(peer)) {
                1
            } else {
                0
            }
            if (tier != pass) {
                if (pass == 0 && knownDead) {
                    skipped++
                }
                continue
            }
            attempted++
            let response = transport.send(peer, MQProtocol.metaSync(MQMetaSyncRequest(transport.selfIndex)))
            match (response) {
                case None =>
                    log.warn("metadata sync from peer ${peer} failed: connection unavailable")
                case Some(message) =>
                    if (message.command == Command.ERROR) {
                        log.warn("metadata sync from peer ${peer} failed: ${MQProtocol.asResult(message).message}")
                        continue
                    }
                    match (MQProtocol.asPayload<MQMetaSnapshot>(message)) {
                        case Some(snapshot) =>
                            mergeSnapshot(snapshot)
                            clearPendingPeers()
                            return
                        case None =>
                            log.warn("metadata sync from peer ${peer} failed: response is not a snapshot")
                    }
            }
            }
        }
        if (attempted == 0) {
            log.warn("no reachable peer for metadata sync (skipped ${skipped} known-dead)")
        } else {
            log.warn("no peer returned a usable snapshot, using local metadata")
        }
    }

    protected func applyRemote(assignment: MQTopicAssignment): MetaApplyResult {
        if (!MQAssignment.validate(assignment, transport.nodeCount)) {
            log.warn("reject malformed assignment for topic '${assignment.topic}' from node ${assignment.origin}")
            return MetaApplyResult.Invalid
        }
        let nextStart = MQAssignment.nextStart(assignment.startNodeIndex, assignment.queueNum, transport.nodeCount)
        // 指针只增不减：乱序到达的旧分配不能把轮转指针拉回去（A33）
        let current = store.nextStartNode
        let persisted = if (nextStart > current) { nextStart } else { current }
        let result = store.applyTopic(assignment, nextStart: persisted)
        if (result == MetaApplyResult.Applied) {
            notifyTopicApplied(assignment.topic)
            flushPendingGroups(assignment.topic)
        }
        result
    }

    protected func applyRemoteGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        let result = store.applyGroup(meta)
        if (result == MetaApplyResult.TopicMissing) {
            // 主题已被墓碑删除时直接拒绝（迟到组不得复活），与「尚未到达」区分开
            if (store.topicTombstone(meta.topic).isSome()) {
                log.warn("reject group '${meta.subscribeGroup}' for topic '${meta.topic}': topic was deleted")
                return result
            }
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

    /** 收到 peer 的墓碑广播：落盘后若本地条目确实消失，连带清理队列/游标/订阅/计数器。 */
    protected func applyRemoteTombstone(tombstone: MQMetaTombstone): MetaApplyResult {
        let result = store.applyTombstone(tombstone)
        if (result == MetaApplyResult.Applied) {
            notifyDeletedIfGone(tombstone)
        }
        result
    }

    /**
     * 合并全量快照：应用条目与墓碑 → 本地更旧且快照缺失的条目视为删除 → 指针只进不退。
     *
     * 墓碑让「离线节点重启后复活已删主题/组」不再发生（A25）；缺失扫描是墓碑被 GC 后的兜底。
     */
    private func mergeSnapshot(snapshot: MQMetaSnapshot): Unit {
        for (tombstone in snapshot.tombstones) {
            if (store.applyTombstone(tombstone) == MetaApplyResult.Applied) {
                notifyDeletedIfGone(tombstone)
            }
        }
        let topicNames = HashSet<String>()
        for (assignment in snapshot.topics) {
            if (!MQAssignment.validate(assignment, transport.nodeCount)) {
                log.warn("skip malformed topic '${assignment.topic}' from peer snapshot")
                continue
            }
            topicNames.add(assignment.topic)
            match (store.applyTopic(assignment)) {
                case MetaApplyResult.Applied => notifyTopicApplied(assignment.topic)
                case MetaApplyResult.Conflict =>
                    log.warn("snapshot conflict for topic '${assignment.topic}' at revision " +
                        "${assignment.revision}: local queueNum=${describeQueueNum(assignment.topic)}, " +
                        "remote queueNum=${assignment.queueNum}, local is kept")
                case _ => ()
            }
        }
        let groupKeys = HashSet<String>()
        for (meta in snapshot.groups) {
            if (!MQGroup.isValid(meta.subscribeGroup) || !MQTopic.isValid(meta.topic)) {
                log.warn("skip malformed group '${meta.subscribeGroup}' of '${meta.topic}' from peer snapshot")
                continue
            }
            groupKeys.add("${meta.topic}\u{0}${meta.subscribeGroup}")
            match (store.applyGroup(meta)) {
                case MetaApplyResult.TopicMissing =>
                    // 快照里主题随后才应用（或在后面批次），先记下待应用
                    addPendingGroup(meta)
                case MetaApplyResult.Conflict =>
                    log.warn("snapshot conflict for group '${meta.subscribeGroup}' of '${meta.topic}' " +
                        "at revision ${meta.revision}: local is kept")
                case _ => ()
            }
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
                    notifyDeleted(MQDeregisterPayload(MQDeregisterPayload.TOPIC, assignment.topic))
                }
            }
            for (meta in store.allGroups()) {
                if (!groupKeys.contains("${meta.topic}\u{0}${meta.subscribeGroup}") &&
                    !tombstoneKeys.contains("${MQMetaTombstone.KIND_GROUP}\u{0}${meta.topic}\u{0}${meta.subscribeGroup}") &&
                    meta.revision <= snapshot.revision) {
                    log.warn("group '${meta.subscribeGroup}' of '${meta.topic}' is missing from the peer snapshot, dropping it")
                    store.dropGroupLocally(meta.topic, meta.subscribeGroup)
                    notifyDeleted(MQDeregisterPayload(MQDeregisterPayload.GROUP, meta.topic,
                        subscribeGroup: meta.subscribeGroup))
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
            // 不按「已知死亡」跳过：该标记只是最近一次调用失败，节点可能已经恢复；
            // 跳过会让它永久错过变更（反熵要等一个完整周期）。发送失败只登记待补偿（A31）。
            if (transport.send(index, message).isNone()) {
                markPendingPeer(index)
                log.warn("metadata broadcast to node ${index} failed, anti-entropy will catch up")
            }
        }
    }

    private func markPendingPeer(index: Int64): Unit {
        synchronized(pendingPeersLock) {
            pendingPeers.add(index)
        }
    }

    private func clearPendingPeers(): Unit {
        synchronized(pendingPeersLock) {
            pendingPeers.clear()
        }
    }

    /** 应用落地后打开本机队列；回调异常不影响元数据路径。 */
    private func notifyTopicApplied(topic: String): Unit {
        match (topicAppliedCallback) {
            case Some(callback) =>
                try {
                    callback(topic)
                } catch (e: Exception) {
                    log.warn("open queue for applied topic '${topic}' failed: ${e.message}")
                }
            case None => ()
        }
    }

    /**
     * 墓碑已生效且本地条目确实消失时，通知装配层清理队列目录、游标、订阅与计数器。
     *
     * 本地存在更高 revision 的活跃条目（重新注册覆盖墓碑）时不清理，避免删掉刚建好的队列。
     */
    private func notifyDeletedIfGone(tombstone: MQMetaTombstone): Unit {
        let gone = if (tombstone.isTopic()) {
            store.topicOf(tombstone.topic).isNone()
        } else {
            !store.groupExists(tombstone.topic, tombstone.subscribeGroup)
        }
        if (!gone) {
            return
        }
        if (tombstone.isTopic()) {
            notifyDeleted(MQDeregisterPayload(MQDeregisterPayload.TOPIC, tombstone.topic))
        } else {
            notifyDeleted(MQDeregisterPayload(MQDeregisterPayload.GROUP, tombstone.topic,
                subscribeGroup: tombstone.subscribeGroup))
        }
    }

    /** 删除清理回调；异常只记 WARN，不得影响元数据收敛。 */
    private func notifyDeleted(payload: MQDeregisterPayload): Unit {
        match (deletedCallback) {
            case Some(callback) =>
                try {
                    callback(payload)
                } catch (e: Exception) {
                    log.warn("cleanup after deleting ${payload.topic}/${payload.subscribeGroup} failed: ${e.message}")
                }
            case None => ()
        }
    }

    private func describeQueueNum(topic: String): Int64 {
        match (store.topicOf(topic)) {
            case Some(local) => local.queueNum
            case None => 0
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
