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
import fountain::f_log.*
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQTopicAssignment}

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
    private let lock = Mutex()
    private let topicIndex = HashMap<String, MQTopicAssignment>()
    private let groups = HashMap<String, ArrayList<MQSubscribeGroupMeta>>()
    private var nextStart: Int64 = 0
    private var closed = false

    protected init(metaDir: String) {
        this.dir = metaDir
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    protected func load(): Unit {
        synchronized(lock) {
            topicIndex.clear()
            groups.clear()
            nextStart = 0
            loadNextStart()
            loadTopics()
            loadGroups()
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
                    if (existing.queueNum == assignment.queueNum && sameOwners(existing.owners, assignment.owners)) {
                        return MetaApplyResult.Duplicated
                    }
                    log.warn("metadata conflict for topic '${assignment.topic}': keep the first one")
                    return MetaApplyResult.Conflict
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
            for (existing in list) {
                if (existing.subscribeGroup == meta.subscribeGroup) {
                    return MetaApplyResult.Duplicated
                }
            }
            writeAtomically("${groupPath(meta.topic, meta.subscribeGroup)}",
                MQProtocol.encodePayload<MQSubscribeGroupMeta>(meta))
            list.add(meta)
            MetaApplyResult.Applied
        }
    }

    /** 删除主题及其订阅组；返回是否真的删除了。 */
    protected func removeTopic(topic: String): Bool {
        synchronized(lock) {
            let existed = topicIndex.remove(topic).isSome()
            groups.remove(topic)
            let topicFile = topicPath(topic)
            if (exists(topicFile)) {
                remove(topicFile)
            }
            let groupDir = "${dir}/groups/${MQFileNames.escape(topic)}"
            if (exists(groupDir)) {
                remove(groupDir, recursive: true)
            }
            existed
        }
    }

    protected func removeGroup(topic: String, group: String): Bool {
        synchronized(lock) {
            var removed = false
            match (groups.get(topic)) {
                case Some(list) =>
                    let kept = ArrayList<MQSubscribeGroupMeta>()
                    for (meta in list) {
                        if (meta.subscribeGroup == group) {
                            removed = true
                        } else {
                            kept.add(meta)
                        }
                    }
                    groups.add(topic, kept)
                case None => ()
            }
            let path = groupPath(topic, group)
            if (exists(path)) {
                remove(path)
                removed = true
            }
            removed
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
            MQMetaSnapshot(topicList.toArray(), groupList.toArray(), nextStart)
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

    private func topicPath(topic: String): String {
        "${dir}/${MQFileNames.topicFile(topic)}"
    }

    private func groupPath(topic: String, group: String): String {
        "${dir}/${MQFileNames.groupFile(topic, group)}"
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

    private func writeAtomically(path: String, bytes: Array<Byte>): Unit {
        let parent = Path(path).parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let tmp = "${path}.tmp"
        if (exists(tmp)) {
            remove(tmp)
        }
        let file = File.create(tmp)
        try {
            file.write(bytes)
        } finally {
            if (!file.isClosed()) {
                file.close()
            }
        }
        rename(tmp, to: path, overwrite: true)
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
