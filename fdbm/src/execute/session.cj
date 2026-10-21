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
package fountain::fdbm.execute

import std.database.sql.Connection
import std.sync.{AtomicBool, Mutex}
import fountain::f_net.SocketBuffer

/** 事务期间 pin 住的写连接（设计 §9.1）：close 幂等，归还一次。 */
protected class PinnedConnection {
    public let connection: Connection
    public var transactionOpen: Bool = false
    private var closed: Bool = false

    public init(connection: Connection) {
        this.connection = connection
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        try {
            connection.close()
        } catch (_: Exception) {
            ()
        }
    }

    public func isClosed(): Bool {
        closed
    }
}

/**
 * 会话 = 一条 TCP（设计 §9.1）：当前至多一个游标 + 可选的事务 pin。
 *
 * `cursor` / `pinned` 是**跨线程共享状态**（f_net 执行器 / 巡检定时器 / 关停线程），
 * 读写一律经本类的方法与互斥锁（G16）。摘除与关闭都先原子摘除、再关闭，保证只归还一次。
 */
protected class DbdSession {
    public let id: String
    public let buffer: ?SocketBuffer
    public var database: String
    /** 仅供本类维护；读取请用 [currentCursor] / [pinnedConnection]（避免绕过锁）。 */
    private var cursor: ?QueryCursor = None
    private var pinned: ?PinnedConnection = None
    private let lock = Mutex()
    private let closed_ = AtomicBool(false)

    public init(id: String, buffer: ?SocketBuffer, database: String) {
        this.id = id
        this.buffer = buffer
        this.database = database
    }

    public func isClosed(): Bool {
        closed_.load()
    }

    public func isPinned(): Bool {
        synchronized(lock) {
            pinned.isSome()
        }
    }

    public func pinnedConnection(): ?PinnedConnection {
        synchronized(lock) {
            pinned
        }
    }

    public func currentCursor(): ?QueryCursor {
        synchronized(lock) {
            cursor
        }
    }

    /**
     * 安装新游标：会话已关闭 → 立即关闭新游标并返回 `false`（调用方回 `CURSOR_STATE`）；
     * 已有游标 → 先关闭旧游标（同一连接只保留一个游标）。
     */
    public func installCursor(value: QueryCursor): Bool {
        synchronized(lock) {
            if (closed_.load()) {
                try {
                    value.close()
                } catch (_: Exception) {
                    ()
                }
                return false
            }
            match (cursor) {
                case Some(existing) =>
                    try {
                        existing.close()
                    } catch (_: Exception) {
                        ()
                    }
                case None => ()
            }
            cursor = Some(value)
            true
        }
    }

    /** 原子摘除游标（供关闭/巡检使用）；返回后不再接受同一游标的第二次关闭。 */
    public func takeCursor(): ?QueryCursor {
        synchronized(lock) {
            let value = cursor
            cursor = None
            value
        }
    }

    public func pin(value: PinnedConnection): Unit {
        synchronized(lock) {
            pinned = Some(value)
        }
    }

    public func unpin(): ?PinnedConnection {
        synchronized(lock) {
            let value = pinned
            pinned = None
            value
        }
    }

    public func close(): Unit {
        if (closed_.swap(true)) {
            return
        }
        match (takeCursor()) {
            case Some(value) =>
                try {
                    value.close()
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
        match (unpin()) {
            case Some(value) => value.close()
            case None => ()
        }
    }
}
