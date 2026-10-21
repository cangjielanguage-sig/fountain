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

import std.collection.{ArrayList, HashMap}
import std.collection.concurrent.ConcurrentHashMap
import std.fs.*
import std.sync.{AtomicBool, Mutex}
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.{ByteBuffer, LogPosition}
import fountain::f_io.LogClosedException
import fountain::fmq.meta.MQFileNames
import fountain::fmq.queue.{QueueLog}

/**
 * 备份副本落盘：`<logRoot>/backup/<ownerIndex>/<topicEsc>/<queueIndex>/`。
 *
 * 只写入，不参与本队列投递，也不再向外备份。
 */
protected class BackupStore <: Resource {
    private let root: String
    private let maxFileSize: Int64
    private let syncInterval: Int64
    private let logs = ConcurrentHashMap<String, QueueLog>()
    private let owners = HashMap<String, (Int64, String, Int64)>()
    /** 保护 `logs` 的 get-or-create：并发的首批备份不得为同一目录创建两个 `QueueLog`。 */
    private let lock = Mutex()
    private let closed = AtomicBool(false)

    protected init(logRoot: String, maxFileSize: Int64, syncInterval: Int64) {
        this.root = "${logRoot}/backup"
        this.maxFileSize = maxFileSize
        this.syncInterval = syncInterval
    }

    protected func append(ownerIndex: Int64, topic: String, queueIndex: Int64, record: Array<Byte>): Unit {
        if (closed.load()) {
            return
        }
        let key = "${ownerIndex}\u{0}${topic}\u{0}${queueIndex}"
        let maybeLog: ?QueueLog = synchronized(lock) {
            // 关闭可能发生在第一次检查之后、拿到锁之前
            if (closed.load()) {
                None<QueueLog>
            } else {
                match (logs.get(key)) {
                    case Some(existing) => Some(existing)
                    case None =>
                        let dir = "${root}/${ownerIndex}/${MQFileNames.escape(topic)}/${queueIndex}"
                        let created = QueueLog(dir, maxFileSize, syncInterval)
                        logs.add(key, created)
                        owners.add(key, (ownerIndex, topic, queueIndex))
                        Some(created)
                }
            }
        }
        match (maybeLog) {
            case None => ()
            case Some(log) =>
                // 写入由 QueueLog 自身的追加锁串行，放在锁外避免阻塞 get-or-create
                try {
                    log.append(record)
                } catch (_: LogClosedException) {
                    // 关闭与写入并发：关闭方已接管，安全丢弃本条
                }
        }
    }

    /** 全部备份日志（清理器按位点回收段时使用）。 */
    protected func allLogs(): Array<(Int64, String, Int64, QueueLog)> {
        let result = ArrayList<(Int64, String, Int64, QueueLog)>()
        synchronized(lock) {
            for ((key, log) in logs) {
                match (owners.get(key)) {
                    case Some(item) => result.add((item[0], item[1], item[2], log))
                    case None => ()
                }
            }
        }
        result.toArray()
    }

    /**
     * 落备份位点：只允许前进，回退请求忽略。
     *
     * 位点是附加文件（`cursors/<group>.cursor`），旧节点忽略它即可。
     */
    protected func saveCursor(ownerIndex: Int64, topic: String, queueIndex: Int64, group: String,
        position: LogPosition): Unit {
        if (closed.load()) {
            return
        }
        match (loadCursor(ownerIndex, topic, queueIndex, group)) {
            case Some(existing) =>
                if (existing.seq > position.seq ||
                    (existing.seq == position.seq && existing.offset >= position.offset)) {
                    return
                }
            case None => ()
        }
        writeCursor(cursorPath(ownerIndex, topic, queueIndex, group), position)
    }

    /** 读备份位点。 */
    protected func loadCursor(ownerIndex: Int64, topic: String, queueIndex: Int64, group: String): ?LogPosition {
        let path = cursorPath(ownerIndex, topic, queueIndex, group)
        if (!exists(path)) {
            return None<LogPosition>
        }
        try {
            let bytes = readAll(path)
            let codec = DefaultCodec()
            try {
                let buffer = ByteBuffer(bytes)
                let seq = match (codec.decode<Int64>(buffer)) {
                    case Some(value) => value
                    case None => return None<LogPosition>
                }
                let offset = match (codec.decode<Int64>(buffer)) {
                    case Some(value) => value
                    case None => return None<LogPosition>
                }
                Some(LogPosition(seq, offset))
            } finally {
                codec.release()
            }
        } catch (_: Exception) {
            None<LogPosition>
        }
    }

    /** 该备份队列全部组位点的最小段号；无位点时返回 `Int64.Max`（不保留历史段）。 */
    protected func cursorFloor(ownerIndex: Int64, topic: String, queueIndex: Int64): Int64 {
        let dir = cursorDir(ownerIndex, topic, queueIndex)
        if (!exists(dir)) {
            return Int64.Max
        }
        // 用数组做盒子：闭包不能捕获可变局部变量
        let floor = Array<Int64>(1, repeat: Int64.Max)
        let seen = Array<Bool>(1, repeat: false)
        Directory.walk(dir) {info: FileInfo =>
            if (!info.isDirectory() && info.name.endsWith(".cursor")) {
                let group = MQFileNames.unescape(info.name[0..info.name.size - 7])
                match (loadCursor(ownerIndex, topic, queueIndex, group)) {
                    case Some(position) =>
                        seen[0] = true
                        if (position.seq < floor[0]) {
                            floor[0] = position.seq
                        }
                    case None => ()
                }
            }
            true
        }
        if (seen[0]) {
            floor[0]
        } else {
            Int64.Max
        }
    }

    private func cursorDir(ownerIndex: Int64, topic: String, queueIndex: Int64): String {
        "${root}/${ownerIndex}/${MQFileNames.escape(topic)}/${queueIndex}/cursors"
    }

    private func cursorPath(ownerIndex: Int64, topic: String, queueIndex: Int64, group: String): String {
        "${cursorDir(ownerIndex, topic, queueIndex)}/${MQFileNames.escape(group)}.cursor"
    }

    private func writeCursor(path: String, position: LogPosition): Unit {
        let parent = Path(path).parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let codec = DefaultCodec()
        var bytes: Array<Byte> = []
        try {
            codec.encode(position.seq).encode(position.offset)
            bytes = codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
        let tmp = "${path}.tmp"
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

    /** 当前实例数（并发用例据此断言只创建了一个 `QueueLog`）。 */
    protected prop instanceCount: Int64 {
        get() {
            synchronized(lock) {
                logs.size
            }
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        synchronized(lock) {
            for ((key, log) in logs) {
                log.close()
                logs.remove(key)
            }
        }
    }
}
