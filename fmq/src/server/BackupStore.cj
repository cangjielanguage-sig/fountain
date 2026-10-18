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

import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, Mutex}
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
