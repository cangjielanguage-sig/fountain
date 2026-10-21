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
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQMetaTombstone, MQTopicAssignment}

/** 应用一条元数据变更的结果。 */
public enum MetaApplyResult <: Equatable<MetaApplyResult> & ToString {
    | Applied
    | Duplicated
    | Conflict

    public operator func ==(other: MetaApplyResult): Bool {
        match ((this, other)) {
            case (Applied, Applied) => true
            case (Duplicated, Duplicated) => true
            case (Conflict, Conflict) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Applied => "applied"
            case Duplicated => "duplicated"
            case Conflict => "conflict"
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
    private let lock = Mutex()
    private let topicIndex = HashMap<String, MQTopicAssignment>()
    private let groups = HashMap<String, ArrayList<MQSubscribeGroupMeta>>()
    private let tombstones = HashMap<String, MQMetaTombstone>()
    /** 本节点已发出的最大 revision（Lamport 计数） */
    private var revision: Int64 = 0
    private var nextStart: Int64 = 0
    private var closed = false

    protected init(metaDir: String, origin!: Int64 = 0) {
        this.dir = metaDir
        this.origin = origin
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
            revision = maxRevisionLocked()
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
     * 应用主题分配。`nextStart` 不为空时同步推进轮转指针（只有收到注册的节点会传）。
     */
    protected func applyTopic(assignment: MQTopicAssignment, nextStart!: ?Int64 = None): MetaApplyResult {
        synchronized(lock) {
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
            if (let Some(value) <- nextStart) {
                this.nextStart = value
                writeAtomically("${dir}/assign.meta", encodeNextStart(value))
            }
            MetaApplyResult.Applied
        }
    }

    protected func applyGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        synchronized(lock) {
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
            MetaApplyResult.Applied
        }
    }

    /**
     * 删除主题及其订阅组：先写墓碑，再删元数据。
     *
     * 返回墓碑（调用方负责广播）；主题不存在返回 `None`。
     */
    protected func removeTopic(topic: String): ?MQMetaTombstone {
        synchronized(lock) {
            if (topicIndex.get(topic).isNone()) {
                return None<MQMetaTombstone>
            }
            let tombstone = newTombstoneLocked(MQMetaTombstone.KIND_TOPIC, topic, '')
            tombstones.add(tombstone.key(), tombstone)
            dropTopicLocked(topic)
            Some(tombstone)
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
     * 本地同 key 的条目 revision 不高于墓碑时一并删除；墓碑本身按 revision 只进不退。
     */
    protected func applyTombstone(tombstone: MQMetaTombstone): MetaApplyResult {
        synchronized(lock) {
            let key = tombstone.key()
            var applied = true
            match (tombstones.get(key)) {
                case Some(existing) =>
                    if (!isNewer(tombstone.revision, tombstone.origin, existing.revision, existing.origin)) {
                        applied = false
                    }
                case None => ()
            }
            if (applied) {
                writeTombstoneLocked(tombstone)
                tombstones.add(key, tombstone)
            }
            if (tombstone.isTopic()) {
                match (topicIndex.get(tombstone.topic)) {
                    case Some(local) =>
                        if (local.revision <= tombstone.revision) {
                            dropTopicLocked(tombstone.topic)
                        }
                    case None => ()
                }
            } else {
                match (groupOfLocked(tombstone.topic, tombstone.subscribeGroup)) {
                    case Some(local) =>
                        if (local.revision <= tombstone.revision) {
                            dropGroupLocked(tombstone.topic, tombstone.subscribeGroup)
                        }
                    case None => ()
                }
            }
            if (applied) { MetaApplyResult.Applied } else { MetaApplyResult.Duplicated }
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

    private static func isNewer(remoteRevision: Int64, remoteOrigin: Int64, localRevision: Int64,
        localOrigin: Int64): Bool {
        remoteRevision > localRevision || (remoteRevision == localRevision && remoteOrigin > localOrigin)
    }

    private static func sameAssignment(left: MQTopicAssignment, right: MQTopicAssignment): Bool {
        left.queueNum == right.queueNum && left.delayingMs == right.delayingMs &&
            sameOwners(left.owners, right.owners)
    }

    private func groupExistsLocked(topic: String, group: String): Bool {
        groupOfLocked(topic, group).isSome()
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

    /** 删除主题的本地状态与文件（不含墓碑）。 */
    private func dropTopicLocked(topic: String): Unit {
        topicIndex.remove(topic)
        groups.remove(topic)
        let topicFile = topicPath(topic)
        if (exists(topicFile)) {
            remove(topicFile)
        }
        let groupDir = "${dir}/groups/${MQFileNames.escape(topic)}"
        if (exists(groupDir)) {
            remove(groupDir, recursive: true)
        }
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
                    case Some(assignment) => topicIndex.add(assignment.topic, assignment)
                    case None => log.error("skip corrupted topic metadata ${info.path}")
                }
            }
        }
    }

    private func loadGroups(): Unit {
        let groupRoot = "${dir}/groups"
        if (!exists(groupRoot)) {
            return
        }
        walkFiles(groupRoot) {info: FileInfo =>
            if (info.name.endsWith(".meta")) {
                match (MQProtocol.decodePayload<MQSubscribeGroupMeta>(readAll(info.path.toString()))) {
                    case Some(meta) =>
                        match (groups.get(meta.topic)) {
                            case Some(list) => list.add(meta)
                            case None =>
                                let list = ArrayList<MQSubscribeGroupMeta>()
                                list.add(meta)
                                groups.add(meta.topic, list)
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
