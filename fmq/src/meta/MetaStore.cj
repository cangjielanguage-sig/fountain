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
package fountain::fmq.meta

import std.collection.{ArrayList, HashMap}
import std.fs.*
import std.sync.Mutex
import std.time.DateTime
import fountain::f_log.*
import fountain::f_mq.base.{MQGroup, MQProtocol, MQTopic}
import fountain::f_mq.base.model.{MQSubscribeGroupMeta, MQTopicMeta}
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQMetaTombstone, MQTopicAssignment}

/** 应用一条元数据变更的结果。 */
public enum MetaApplyResult <: Equatable<MetaApplyResult> & ToString {
    | Applied
    | Duplicated
    | Conflict
    /** 组依赖的主题不存在（组先于主题到达时进入待应用队列） */
    | TopicMissing
    /** 载荷结构非法（分配字段越界、组名非法等），不得落盘 */
    | Invalid
    /** 同 key 的墓碑更新：迟到的旧条目被墓碑挡住，不落盘、不复活 */
    | Tombstoned

    public operator func ==(other: MetaApplyResult): Bool {
        match ((this, other)) {
            case (Applied, Applied) => true
            case (Duplicated, Duplicated) => true
            case (Conflict, Conflict) => true
            case (TopicMissing, TopicMissing) => true
            case (Invalid, Invalid) => true
            case (Tombstoned, Tombstoned) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Applied => "applied"
            case Duplicated => "duplicated"
            case Conflict => "conflict"
            case TopicMissing => "topic-missing"
            case Invalid => "invalid"
            case Tombstoned => "tombstoned"
        }
    }
}

/**
 * `metas/` 目录持久化 + 内存索引。
 *
 * 布局：`assign.meta`、`topics/<topicEsc>.meta`、`groups/<topicEsc>/<groupEsc>.meta`。
 * 所有写入走「`.tmp` + rename」；加载时坏文件记 ERROR 后跳过，不阻断启动。
 */
protected class MetaStore <: Resource {
    private static let log = LoggerFactory.getLogger("fountain::fmq.meta.MetaStore")

    private let dir: String
    /** 本节点下标；同 revision 时用 origin 打破平局 */
    private let origin: Int64
    /** 集群节点数；0 表示未知（加载时只做与节点数无关的结构校验） */
    private let nodeCount: Int64
    private let lock = Mutex()
    private let topicIndex = HashMap<String, MQTopicAssignment>()
    private let groups = HashMap<String, ArrayList<MQSubscribeGroupMeta>>()
    private let tombstones = HashMap<String, MQMetaTombstone>()
    /** 本节点已发出的最大 revision（Lamport 计数） */
    private var revision: Int64 = 0
    private var nextStart: Int64 = 0
    private var closed = false

    protected init(metaDir: String, origin!: Int64 = 0, nodeCount!: Int64 = 0) {
        this.dir = metaDir
        this.origin = origin
        this.nodeCount = nodeCount
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    protected func load(): Unit {
        synchronized(lock) {
            topicIndex.clear()
            groups.clear()
            tombstones.clear()
            nextStart = 0
            revision = 0
            loadNextStart()
            loadRevision()
            loadTopics()
            loadGroups()
            loadTombstones()
            // 崩溃窗口可能留下「条目与墓碑共存」：按 isNewer 收敛，不留复活态（R2-G2）
            convergeTombstonesLocked()
            revision = maxRevisionLocked()
        }
    }

    /**
     * 加载后收敛「条目与墓碑共存」的状态（调用方必须持有 `lock`）。
     *
     * 条目版本更新 → 删墓碑（重新注册胜过旧墓碑）；墓碑版本更新 → 删条目；
     * 逐条容错：单条失败只记 ERROR，下一次加载会再收敛一遍。
     */
    private func convergeTombstonesLocked(): Unit {
        let pending = ArrayList<MQMetaTombstone>()
        for ((_, tombstone) in tombstones) {
            pending.add(tombstone)
        }
        for (tombstone in pending) {
            try {
                if (tombstone.isTopic()) {
                    match (topicIndex.get(tombstone.topic)) {
                        case Some(local) =>
                            if (isNewer(local.revision, local.origin, tombstone.revision, tombstone.origin)) {
                                dropTombstoneLocked(MQMetaTombstone.KIND_TOPIC, tombstone.topic, '')
                            } else {
                                log.warn("topic '${tombstone.topic}' survived a newer tombstone on disk, " +
                                    "dropping it")
                                dropTopicLocked(tombstone.topic)
                            }
                        case None => ()
                    }
                } else {
                    match (groupOfLocked(tombstone.topic, tombstone.subscribeGroup)) {
                        case Some(local) =>
                            if (isNewer(local.revision, local.origin, tombstone.revision, tombstone.origin)) {
                                dropTombstoneLocked(MQMetaTombstone.KIND_GROUP, tombstone.topic,
                                    tombstone.subscribeGroup)
                            } else {
                                log.warn("group '${tombstone.subscribeGroup}' of '${tombstone.topic}' " +
                                    "survived a newer tombstone on disk, dropping it")
                                dropGroupLocked(tombstone.topic, tombstone.subscribeGroup)
                            }
                        case None => ()
                    }
                }
            } catch (e: Exception) {
                log.error("cannot converge tombstone '${tombstone.key()}': ${e.message}")
            }
        }
    }

    protected func topicOf(topic: String): ?MQTopicAssignment {
        synchronized(lock) {
            topicIndex.get(topic)
        }
    }

    protected func topics(): Array<MQTopicAssignment> {
        synchronized(lock) {
            let result = ArrayList<MQTopicAssignment>()
            for ((_, assignment) in topicIndex) {
                result.add(assignment)
            }
            result.toArray()
        }
    }

    /** 本地全部订阅组（快照合并时做缺失检测）。 */
    protected func allGroups(): Array<MQSubscribeGroupMeta> {
        synchronized(lock) {
            let result = ArrayList<MQSubscribeGroupMeta>()
            for ((_, list) in groups) {
                for (meta in list) {
                    result.add(meta)
                }
            }
            result.toArray()
        }
    }

    protected func groupsOf(topic: String): Array<MQSubscribeGroupMeta> {
        synchronized(lock) {
            match (groups.get(topic)) {
                case Some(list) => list.toArray()
                case None => Array<MQSubscribeGroupMeta>()
            }
        }
    }

    protected func groupExists(topic: String, group: String): Bool {
        synchronized(lock) {
            match (groups.get(topic)) {
                case None => false
                case Some(list) =>
                    for (meta in list) {
                        if (meta.subscribeGroup == group) {
                            return true
                        }
                    }
                    false
            }
        }
    }

    protected prop nextStartNode: Int64 {
        get() {
            synchronized(lock) {
                nextStart
            }
        }
    }

    /**
     * 注册主题：检查是否存在、分配、写盘、推进指针全在同一个临界区内完成（A28）。
     *
     * 返回「结果 + 落盘的分配」；`Duplicated` 时分配为 `None`。
     */
    protected func registerTopic(meta: MQTopicMeta, nodeCount: Int64): (MetaApplyResult, ?MQTopicAssignment) {
        if (meta.queueNum < 1 || nodeCount < 1) {
            return (MetaApplyResult.Conflict, None<MQTopicAssignment>)
        }
        synchronized(lock) {
            if (topicIndex.get(meta.topic).isSome()) {
                return (MetaApplyResult.Duplicated, None<MQTopicAssignment>)
            }
            let start = nextStart % nodeCount
            let assignment = MQAssignment.allocate(meta.topic, meta.queueNum, nodeCount, start,
                delayingMs: meta.delayingMs, revision: nextRevisionLocked(), origin: origin)
            let next = MQAssignment.nextStart(start, meta.queueNum, nodeCount)
            writeAtomically(topicPath(assignment.topic), MQProtocol.encodePayload<MQTopicAssignment>(assignment))
            topicIndex.add(assignment.topic, assignment)
            dropTombstoneLocked(MQMetaTombstone.KIND_TOPIC, assignment.topic, "")
            this.nextStart = next
            writeAtomically("${dir}/assign.meta", encodeNextStart(next))
            (MetaApplyResult.Applied, Some(assignment))
        }
    }

    /** 注册订阅组：主题存在性与组存在性检查、写盘在同一个临界区内完成（A28/A36）。 */
    protected func registerGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        if (!MQGroup.isValid(meta.subscribeGroup) || !MQTopic.isValid(meta.topic)) {
            log.warn("reject group registration '${meta.subscribeGroup}' of '${meta.topic}': ${invalidReason(meta)}")
            return MetaApplyResult.Invalid
        }
        synchronized(lock) {
            if (topicIndex.get(meta.topic).isNone()) {
                return MetaApplyResult.TopicMissing
            }
            if (groupExistsLocked(meta.topic, meta.subscribeGroup)) {
                return MetaApplyResult.Duplicated
            }
            let versioned = MQSubscribeGroupMeta(meta.topic, meta.subscribeGroup, revision: nextRevisionLocked(),
                origin: origin)
            writeAtomically(groupPath(versioned.topic, versioned.subscribeGroup),
                MQProtocol.encodePayload<MQSubscribeGroupMeta>(versioned))
            let list = match (groups.get(versioned.topic)) {
                case Some(items) => items
                case None =>
                    let items = ArrayList<MQSubscribeGroupMeta>()
                    groups.add(versioned.topic, items)
                    items
            }
            list.add(versioned)
            dropTombstoneLocked(MQMetaTombstone.KIND_GROUP, versioned.topic, versioned.subscribeGroup)
            MetaApplyResult.Applied
        }
    }

    /**
     * 应用主题分配。`nextStart` 不为空时同步推进轮转指针（只有收到注册的节点会传）。
     */
    protected func applyTopic(assignment: MQTopicAssignment, nextStart!: ?Int64 = None): MetaApplyResult {
        synchronized(lock) {
            // 墓碑也是一次带版本的变更：迟到的旧分配不能把已删主题带回来（R2-S1）
            if (!acceptOverTombstoneLocked(MQMetaTombstone.KIND_TOPIC, assignment.topic, "",
                assignment.revision, assignment.origin)) {
                log.warn("reject topic '${assignment.topic}' at revision ${assignment.revision}: " +
                    "blocked by tombstone")
                return MetaApplyResult.Tombstoned
            }
            match (topicIndex.get(assignment.topic)) {
                case Some(existing) =>
                    if (!isNewer(assignment.revision, assignment.origin, existing.revision, existing.origin)) {
                        if (assignment.revision == existing.revision && assignment.origin == existing.origin &&
                            !sameAssignment(existing, assignment)) {
                            log.warn("metadata conflict for topic '${assignment.topic}' at revision " +
                                "${assignment.revision}: keep the first one")
                            return MetaApplyResult.Conflict
                        }
                        // 更旧的版本（乱序到货）直接忽略
                        return MetaApplyResult.Duplicated
                    }
                case None => ()
            }
            writeAtomically("${topicPath(assignment.topic)}", MQProtocol.encodePayload<MQTopicAssignment>(assignment))
            topicIndex.add(assignment.topic, assignment)
            // 活条目已胜出：墓碑只会挡住后续更旧的条目，保留它会压低 tombstoneFloor，必须移除
            dropTombstoneLocked(MQMetaTombstone.KIND_TOPIC, assignment.topic, "")
            if (let Some(value) <- nextStart) {
                this.nextStart = value
                writeAtomically("${dir}/assign.meta", encodeNextStart(value))
            }
            MetaApplyResult.Applied
        }
    }

    protected func applyGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        if (!MQGroup.isValid(meta.subscribeGroup) || !MQTopic.isValid(meta.topic)) {
            log.warn("reject group '${meta.subscribeGroup}' of '${meta.topic}': ${invalidReason(meta)}")
            return MetaApplyResult.Invalid
        }
        synchronized(lock) {
            // 组墓碑先于主题存在性判定：已删组不得因主题仍在而复活（R2-S1）
            if (!acceptOverTombstoneLocked(MQMetaTombstone.KIND_GROUP, meta.topic, meta.subscribeGroup,
                meta.revision, meta.origin)) {
                log.warn("reject group '${meta.subscribeGroup}' of '${meta.topic}' at revision " +
                    "${meta.revision}: blocked by tombstone")
                return MetaApplyResult.Tombstoned
            }
            if (topicIndex.get(meta.topic).isNone()) {
                // 组先于主题到达（网络乱序）或主题已删除：拒绝，交给 Syncer 的待应用队列
                return MetaApplyResult.TopicMissing
            }
            let list = match (groups.get(meta.topic)) {
                case Some(items) => items
                case None =>
                    let items = ArrayList<MQSubscribeGroupMeta>()
                    groups.add(meta.topic, items)
                    items
            }
            var replaced = false
            for (i in 0..list.size) {
                let existing = list[i]
                if (existing.subscribeGroup != meta.subscribeGroup) {
                    continue
                }
                if (!isNewer(meta.revision, meta.origin, existing.revision, existing.origin)) {
                    return MetaApplyResult.Duplicated
                }
                list[i] = meta
                replaced = true
                break
            }
            if (!replaced) {
                list.add(meta)
            }
            writeAtomically("${groupPath(meta.topic, meta.subscribeGroup)}",
                MQProtocol.encodePayload<MQSubscribeGroupMeta>(meta))
            dropTombstoneLocked(MQMetaTombstone.KIND_GROUP, meta.topic, meta.subscribeGroup)
            MetaApplyResult.Applied
        }
    }

    /**
     * 删除主题及其订阅组：先写墓碑，再删元数据。
     *
     * 返回墓碑列表（主题墓碑在首位，随后是该主题下每个订阅组的墓碑），调用方负责逐条广播；
     * 主题不存在返回空列表。级联写组墓碑是为了让对端在只收到组快照时不会重建孤儿组。
     */
    protected func removeTopic(topic: String): Array<MQMetaTombstone> {
        synchronized(lock) {
            if (topicIndex.get(topic).isNone()) {
                return []
            }
            let result = ArrayList<MQMetaTombstone>()
            let topicTombstone = newTombstoneLocked(MQMetaTombstone.KIND_TOPIC, topic, '')
            tombstones.add(topicTombstone.key(), topicTombstone)
            result.add(topicTombstone)
            match (groups.get(topic)) {
                case Some(list) =>
                    for (meta in list) {
                        let groupTombstone = newTombstoneLocked(MQMetaTombstone.KIND_GROUP, topic,
                            meta.subscribeGroup)
                        tombstones.add(groupTombstone.key(), groupTombstone)
                        result.add(groupTombstone)
                    }
                case None => ()
            }
            dropTopicLocked(topic)
            result.toArray()
        }
    }

    /** 删除订阅组：先写墓碑，再删元数据。返回墓碑；组不存在返回 `None`。 */
    protected func removeGroup(topic: String, group: String): ?MQMetaTombstone {
        synchronized(lock) {
            if (!groupExistsLocked(topic, group)) {
                return None<MQMetaTombstone>
            }
            let tombstone = newTombstoneLocked(MQMetaTombstone.KIND_GROUP, topic, group)
            tombstones.add(tombstone.key(), tombstone)
            dropGroupLocked(topic, group)
            Some(tombstone)
        }
    }

    /**
     * 应用一条墓碑（来自广播或快照）。
     *
     * 胜负与条目之间用同一套 `isNewer` 规则：墓碑只有赢过同 key 的活条目与已有墓碑才生效。
     * 输掉时零副作用——不写墓碑、不删条目、不回调（R2-S2）。
     */
    protected func applyTombstone(tombstone: MQMetaTombstone): MetaApplyResult {
        synchronized(lock) {
            // 先判活条目：`(rev 5, origin 9)` 的条目必须挡住 `(rev 5, origin 2)` 的墓碑
            if (tombstone.isTopic()) {
                match (topicIndex.get(tombstone.topic)) {
                    case Some(local) =>
                        if (!isNewer(tombstone.revision, tombstone.origin, local.revision, local.origin)) {
                            return MetaApplyResult.Duplicated
                        }
                    case None => ()
                }
            } else {
                match (groupOfLocked(tombstone.topic, tombstone.subscribeGroup)) {
                    case Some(local) =>
                        if (!isNewer(tombstone.revision, tombstone.origin, local.revision, local.origin)) {
                            return MetaApplyResult.Duplicated
                        }
                    case None => ()
                }
            }
            // 再判已有墓碑：墓碑之间同样只进不退
            let key = tombstone.key()
            match (tombstones.get(key)) {
                case Some(existing) =>
                    if (!isNewer(tombstone.revision, tombstone.origin, existing.revision, existing.origin)) {
                        return MetaApplyResult.Duplicated
                    }
                case None => ()
            }
            writeTombstoneLocked(tombstone)
            tombstones.add(key, tombstone)
            if (tombstone.isTopic()) {
                match (topicIndex.get(tombstone.topic)) {
                    case Some(_) =>
                        for (meta in groupsOfLocked(tombstone.topic)) {
                            if (meta.revision > tombstone.revision) {
                                log.warn("group '${meta.subscribeGroup}' of deleted topic '${tombstone.topic}' " +
                                    "has newer revision ${meta.revision}; dropping it with the topic")
                            }
                        }
                        // 级联删除该主题下的组：主题已不存在，孤儿组只会让后续快照继续扩散
                        dropTopicLocked(tombstone.topic)
                    case None => ()
                }
            } else {
                if (groupOfLocked(tombstone.topic, tombstone.subscribeGroup).isSome()) {
                    dropGroupLocked(tombstone.topic, tombstone.subscribeGroup)
                }
            }
            MetaApplyResult.Applied
        }
    }

    /** 本地全部墓碑（快照与反熵用）。 */
    protected func allTombstones(): Array<MQMetaTombstone> {
        synchronized(lock) {
            let result = ArrayList<MQMetaTombstone>()
            for ((_, tombstone) in tombstones) {
                result.add(tombstone)
            }
            result.toArray()
        }
    }

    /**
     * 某主题的主题墓碑。
     *
     * 用来区分「主题不存在是因为还没到达」与「主题已被删除」（后者拒绝迟到组）。
     */
    protected func topicTombstone(topic: String): ?MQMetaTombstone {
        synchronized(lock) {
            tombstones.get("${MQMetaTombstone.KIND_TOPIC}\u{0}${topic}")
        }
    }

    /** 生成下一个 revision 并落盘（Lamport 计数，不看墙钟）。 */
    protected func nextRevision(): Int64 {
        synchronized(lock) {
            nextRevisionLocked()
        }
    }

    /**
     * 回收过期墓碑：超过 TTL 且同 key 没有更新的活跃条目。
     *
     * 返回回收数量。
     */
    protected func gcTombstones(nowMs: Int64, ttlMs: Int64): Int64 {
        synchronized(lock) {
            let victims = ArrayList<String>()
            for ((key, tombstone) in tombstones) {
                if (nowMs - tombstone.deletedAtMs <= ttlMs) {
                    continue
                }
                let resurrected = if (tombstone.isTopic()) {
                    match (topicIndex.get(tombstone.topic)) {
                        case Some(local) => local.revision > tombstone.revision
                        case None => false
                    }
                } else {
                    match (groupOfLocked(tombstone.topic, tombstone.subscribeGroup)) {
                        case Some(local) => local.revision > tombstone.revision
                        case None => false
                    }
                }
                if (!resurrected) {
                    victims.add(key)
                }
            }
            for (key in victims) {
                match (tombstones.remove(key)) {
                    case Some(tombstone) =>
                        let path = tombstonePath(tombstone)
                        if (exists(path)) {
                            remove(path)
                        }
                    case None => ()
                }
            }
            Int64(victims.size)
        }
    }

    protected func advanceNextStart(value: Int64): Unit {
        synchronized(lock) {
            this.nextStart = value
            writeAtomically("${dir}/assign.meta", encodeNextStart(value))
        }
    }

    protected func snapshot(): MQMetaSnapshot {
        synchronized(lock) {
            let topicList = ArrayList<MQTopicAssignment>()
            for ((_, assignment) in topicIndex) {
                topicList.add(assignment)
            }
            let groupList = ArrayList<MQSubscribeGroupMeta>()
            for ((_, list) in groups) {
                for (meta in list) {
                    groupList.add(meta)
                }
            }
            let tombstoneList = ArrayList<MQMetaTombstone>()
            var floor = Int64.Max
            for ((_, tombstone) in tombstones) {
                tombstoneList.add(tombstone)
                if (tombstone.revision < floor) {
                    floor = tombstone.revision
                }
            }
            MQMetaSnapshot(topicList.toArray(), groupList.toArray(), nextStart,
                tombstones: tombstoneList.toArray(), revision: maxRevisionLocked(),
                tombstoneFloor: if (tombstoneList.size == 0) {0} else {floor})
        }
    }

    public func isClosed(): Bool {
        synchronized(lock) {
            closed
        }
    }

    public func close(): Unit {
        synchronized(lock) {
            closed = true
        }
    }

    // ===== 内部 =====

    /**
     * 快照合并时「本地有、快照没有，且本地更旧」的条目视为已删除。
     *
     * 墓碑被 GC 之后的兜底路径；不写墓碑（对端可能仍持有，反熵会补齐）。
     */
    protected func dropTopicLocally(topic: String): Unit {
        synchronized(lock) {
            dropTopicLocked(topic)
        }
    }

    protected func dropGroupLocally(topic: String, group: String): Unit {
        synchronized(lock) {
            dropGroupLocked(topic, group)
        }
    }

    private func topicPath(topic: String): String {
        "${dir}/${MQFileNames.topicFile(topic)}"
    }

    private func groupPath(topic: String, group: String): String {
        "${dir}/${MQFileNames.groupFile(topic, group)}"
    }

    /** 组载荷非法的原因：区分组名与主题，WARN 里能直接指向失败字段（R2-G10）。 */
    private static func invalidReason(meta: MQSubscribeGroupMeta): String {
        if (!MQGroup.isValid(meta.subscribeGroup)) {
            "invalid group name '${meta.subscribeGroup}'"
        } else {
            "invalid topic '${meta.topic}'"
        }
    }

    private static func isNewer(remoteRevision: Int64, remoteOrigin: Int64, localRevision: Int64,
        localOrigin: Int64): Bool {
        remoteRevision > localRevision || (remoteRevision == localRevision && remoteOrigin > localOrigin)
    }

    /** 同 key 的墓碑（调用方必须持有 `lock`）。 */
    private func tombstoneOfLocked(kind: String, topic: String, group: String): ?MQMetaTombstone {
        let key = if (kind == MQMetaTombstone.KIND_TOPIC) {
            "${kind}\u{0}${topic}"
        } else {
            "${kind}\u{0}${topic}\u{0}${group}"
        }
        tombstones.get(key)
    }

    /**
     * 条目能否越过同 key 的墓碑（调用方必须持有 `lock`）。
     *
     * 与条目之间同一套 `isNewer` 语义：revision 大者胜，同 revision 比 origin；
     * 完全相等时墓碑胜（删除是终态，迟到重放不得复活）。
     */
    private func acceptOverTombstoneLocked(kind: String, topic: String, group: String, revision: Int64,
        origin: Int64): Bool {
        match (tombstoneOfLocked(kind, topic, group)) {
            case Some(tombstone) => isNewer(revision, origin, tombstone.revision, tombstone.origin)
            case None => true
        }
    }

    /**
     * 删除同 key 的墓碑（条目已以更高版本胜出时）。
     *
     * 内存移除是权威结果；文件删除失败只记 ERROR，下次加载按「条目更新 → 删墓碑」再次收敛。
     */
    private func dropTombstoneLocked(kind: String, topic: String, group: String): Unit {
        let key = if (kind == MQMetaTombstone.KIND_TOPIC) {
            "${kind}\u{0}${topic}"
        } else {
            "${kind}\u{0}${topic}\u{0}${group}"
        }
        if (tombstones.remove(key).isNone()) {
            return
        }
        let path = tombstonePath(MQMetaTombstone(kind, topic, group, 0, 0, 0))
        try {
            if (exists(path)) {
                remove(path)
            }
        } catch (e: Exception) {
            log.error("cannot remove tombstone file ${path}: ${e.message}")
        }
    }

    private static func sameAssignment(left: MQTopicAssignment, right: MQTopicAssignment): Bool {
        left.queueNum == right.queueNum && left.delayingMs == right.delayingMs &&
            sameOwners(left.owners, right.owners)
    }

    private func groupExistsLocked(topic: String, group: String): Bool {
        groupOfLocked(topic, group).isSome()
    }

    /** 某主题下的全部组（快照副本，级联删除时安全遍历）。 */
    private func groupsOfLocked(topic: String): Array<MQSubscribeGroupMeta> {
        match (groups.get(topic)) {
            case Some(list) => list.toArray()
            case None => Array<MQSubscribeGroupMeta>()
        }
    }

    private func groupOfLocked(topic: String, group: String): ?MQSubscribeGroupMeta {
        match (groups.get(topic)) {
            case None => None<MQSubscribeGroupMeta>
            case Some(list) =>
                for (meta in list) {
                    if (meta.subscribeGroup == group) {
                        return Some(meta)
                    }
                }
                None<MQSubscribeGroupMeta>
        }
    }

    /**
     * 删除主题的本地状态与文件（不含墓碑）。
     *
     * 顺序固定为「组 → 主题」：反过来的话，中途崩溃会留下没有主题的孤儿组文件（A35）。
     */
    private func dropTopicLocked(topic: String): Unit {
        groups.remove(topic)
        let groupDir = "${dir}/groups/${MQFileNames.escape(topic)}"
        if (exists(groupDir)) {
            remove(groupDir, recursive: true)
        }
        let topicFile = topicPath(topic)
        if (exists(topicFile)) {
            remove(topicFile)
        }
        topicIndex.remove(topic)
    }

    private func dropGroupLocked(topic: String, group: String): Unit {
        match (groups.get(topic)) {
            case Some(list) =>
                let kept = ArrayList<MQSubscribeGroupMeta>()
                for (meta in list) {
                    if (meta.subscribeGroup != group) {
                        kept.add(meta)
                    }
                }
                if (kept.size == 0) {
                    groups.remove(topic)
                } else {
                    groups.add(topic, kept)
                }
            case None => ()
        }
        let path = groupPath(topic, group)
        if (exists(path)) {
            remove(path)
        }
    }

    private func newTombstoneLocked(kind: String, topic: String, group: String): MQMetaTombstone {
        let revision = nextRevisionLocked()
        let tombstone = MQMetaTombstone(kind, topic, group, revision, origin,
            DateTime.now().toUnixTimeStamp().toMilliseconds())
        writeTombstoneLocked(tombstone)
        tombstone
    }

    private func writeTombstoneLocked(tombstone: MQMetaTombstone): Unit {
        writeAtomically(tombstonePath(tombstone), MQProtocol.encodePayload<MQMetaTombstone>(tombstone))
    }

    private func tombstonePath(tombstone: MQMetaTombstone): String {
        "${dir}/tombstones/${tombstoneFileOf(tombstone)}"
    }

    private static func tombstoneFileOf(tombstone: MQMetaTombstone): String {
        let key = if (tombstone.isTopic()) {
            "t_${MQFileNames.escape(tombstone.topic)}"
        } else {
            "g_${MQFileNames.escape(tombstone.topic)}_${MQFileNames.escape(tombstone.subscribeGroup)}"
        }
        "${key}.meta"
    }

    /** 当前可见的最大 revision（含条目与墓碑）。 */
    private func maxRevisionLocked(): Int64 {
        var result = revision
        for ((_, assignment) in topicIndex) {
            if (assignment.revision > result) {
                result = assignment.revision
            }
        }
        for ((_, list) in groups) {
            for (meta in list) {
                if (meta.revision > result) {
                    result = meta.revision
                }
            }
        }
        for ((_, tombstone) in tombstones) {
            if (tombstone.revision > result) {
                result = tombstone.revision
            }
        }
        result
    }

    private func nextRevisionLocked(): Int64 {
        let next = maxRevisionLocked() + 1
        revision = next
        writeAtomically("${dir}/revision.meta", encodeNextStart(next))
        next
    }

    private func loadRevision(): Unit {
        let path = "${dir}/revision.meta"
        if (!exists(path)) {
            return
        }
        match (MQProtocol.decodePayload<Int64>(readAll(path))) {
            case Some(value) => revision = value
            case None => log.error("cannot decode ${path}, fallback revision=0")
        }
    }

    private func loadTombstones(): Unit {
        let tombstoneDir = "${dir}/tombstones"
        if (!exists(tombstoneDir)) {
            return
        }
        walkFiles(tombstoneDir) {info: FileInfo =>
            if (info.name.endsWith(".meta")) {
                match (MQProtocol.decodePayload<MQMetaTombstone>(readAll(info.path.toString()))) {
                    case Some(tombstone) => tombstones.add(tombstone.key(), tombstone)
                    case None => log.error("skip corrupted tombstone ${info.path}")
                }
            }
        }
    }

    private static func sameOwners(left: Array<Int64>, right: Array<Int64>): Bool {
        if (left.size != right.size) {
            return false
        }
        for (i in 0..left.size) {
            if (left[i] != right[i]) {
                return false
            }
        }
        true
    }

    private func loadNextStart(): Unit {
        let path = "${dir}/assign.meta"
        if (!exists(path)) {
            return
        }
        match (MQProtocol.decodePayload<Int64>(readAll(path))) {
            case Some(value) => nextStart = value
            case None => log.error("cannot decode ${path}, fallback nextStart=0")
        }
    }

    private func loadTopics(): Unit {
        let topicDir = "${dir}/topics"
        if (!exists(topicDir)) {
            return
        }
        walkFiles(topicDir) {info: FileInfo =>
            if (info.name.endsWith(".meta")) {
                match (MQProtocol.decodePayload<MQTopicAssignment>(readAll(info.path.toString()))) {
                    case Some(assignment) =>
                        // 可解码不等于合法：owners 数量不符/越界的文件不得进入索引，更不能进快照（A34）
                        let valid = if (nodeCount > 0) {
                            MQAssignment.validate(assignment, nodeCount)
                        } else {
                            MQAssignment.validateStructure(assignment)
                        }
                        if (!valid) {
                            log.error("skip invalid topic metadata ${info.path}: '${assignment.topic}' " +
                                "queueNum=${assignment.queueNum} owners=${assignment.owners.size}")
                        } else {
                            topicIndex.add(assignment.topic, assignment)
                        }
                    case None => log.error("skip corrupted topic metadata ${info.path}")
                }
            }
        }
    }

    private func loadGroups(): Unit {
        // 加载时丢弃孤儿组（主题文件已被删除但组文件还在，旧版本的删除顺序残留）
        // 注意：先加载主题，再调用本方法
        let groupRoot = "${dir}/groups"
        if (!exists(groupRoot)) {
            return
        }
        walkFiles(groupRoot) {info: FileInfo =>
            if (info.name.endsWith(".meta")) {
                match (MQProtocol.decodePayload<MQSubscribeGroupMeta>(readAll(info.path.toString()))) {
                    case Some(meta) =>
                        if (topicIndex.get(meta.topic).isNone()) {
                            log.error("drop orphan group '${meta.subscribeGroup}' of missing topic '${meta.topic}'")
                        } else {
                            match (groups.get(meta.topic)) {
                                case Some(list) => list.add(meta)
                                case None =>
                                    let list = ArrayList<MQSubscribeGroupMeta>()
                                    list.add(meta)
                                    groups.add(meta.topic, list)
                            }
                        }
                    case None => log.error("skip corrupted group metadata ${info.path}")
                }
            }
        }
    }

    private static func encodeNextStart(value: Int64): Array<Byte> {
        MQProtocol.encodePayload<Int64>(value)
    }

    /** 元数据写入统一走 `AtomicFile`：写 → fsync → rename → fsync(parent)。 */
    private func writeAtomically(path: String, bytes: Array<Byte>): Unit {
        AtomicFile().write(path, bytes)
    }

    private static func walkFiles(dir: String, f: (FileInfo) -> Unit): Unit {
        Directory.walk(dir) {info: FileInfo =>
            if (info.isDirectory()) {
                walkFiles(info.path.toString(), f)
            } else {
                f(info)
            }
            true
        }
    }

    private static func readAll(path: String): Array<Byte> {
        let file = File(path, OpenMode.Read)
        try {
            let size = file.info.size
            let bytes = Array<Byte>(size, repeat: 0u8)
            var got = 0i64
            while (got < size) {
                let n = file.read(bytes[got..size])
                if (n <= 0) {
                    break
                }
                got += n
            }
            bytes
        } finally {
            if (!file.isClosed()) {
                file.close()
            }
        }
    }
}
