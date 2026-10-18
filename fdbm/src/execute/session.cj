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

/** 会话 = 一条 TCP（设计 §9.1）：当前至多一个游标 + 可选的事务 pin。 */
protected class DbdSession {
    public let id: String
    public let buffer: ?SocketBuffer
    public var cursor: ?QueryCursor = None
    public var pinned: ?PinnedConnection = None
    public var database: String

    public init(id: String, buffer: ?SocketBuffer, database: String) {
        this.id = id
        this.buffer = buffer
        this.database = database
    }

    public func close(): Unit {
        match (cursor) {
            case Some(value) =>
                try {
                    value.close()
                } catch (_: Exception) {
                    ()
                }
            case None => ()
        }
        cursor = None
        match (pinned) {
            case Some(value) => value.close()
            case None => ()
        }
        pinned = None
    }
}
