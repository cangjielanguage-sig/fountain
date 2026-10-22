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
package fountain::fdbm.server

import std.collection.{ArrayList, HashMap}
import std.sync.{AtomicBool, AtomicInt64, CatchupStyle, Mutex, Timer}
import fountain::f_log.LoggerFactory
import fountain::f_net.SocketBuffer
import fountain::fdbm.execute.DbdSession

/**
 * 会话注册表（设计 §10.3）：一条 TCP 一个会话，键取 `remoteAddress` 的文本形式
 *（`SocketBuffer` 无哈希语义，地址在同一次连接生命周期内唯一且稳定）。
 *
 * f_net 不提供断连回调，因此靠周期巡检 `buffer.isClosed()` 回收游标与 pin 连接。
 */
protected class SessionRegistry <: Resource {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.SessionRegistry')

    private let mutex = Mutex()
    private let sessions = HashMap<String, DbdSession>()
    private let defaultDatabase: String
    private let closed = AtomicBool(false)
    private let anonymous = AtomicInt64(0)
    private var timer: ?Timer = None

    public init(sweepInterval: Duration, defaultDatabase: String) {
        this.defaultDatabase = defaultDatabase
        this.timer = Some(Timer.repeat(sweepInterval, sweepInterval, {=> sweep()}, style: Burst))
    }

    /** 取或建：同一连接永远拿到同一会话。 */
    public func of(buffer: SocketBuffer): DbdSession {
        let key = keyOf(buffer)
        synchronized(mutex) {
            match (sessions.get(key)) {
                case Some(session) => session
                case None =>
                    let session = DbdSession('${key}#${anonymous.fetchAdd(1)}', Some(buffer),
                        defaultDatabase)
                    sessions[key] = session
                    session
            }
        }
    }

    /** 显式移除（用例/测试用）：关闭会话并归还资源。 */
    public func remove(buffer: SocketBuffer): Unit {
        let session = synchronized(mutex) {
            sessions.remove(keyOf(buffer))
        }
        match (session) {
            case Some(value) => value.close()
            case None => ()
        }
    }

    public func closeAll(): Unit {
        if (closed.swap(true)) {
            return
        }
        match (timer) {
            case Some(value) => value.cancel()
            case None => ()
        }
        let pending = synchronized(mutex) {
            let copy = ArrayList<DbdSession>()
            for ((_, session) in sessions) {
                copy.add(session)
            }
            sessions.clear()
            copy.toArray()
        }
        for (session in pending) {
            try {
                session.close()
            } catch (e: Exception) {
                logger.warn('failed to close session ${session.id}: ${e.message}')
            }
        }
    }

    public func close(): Unit {
        closeAll()
    }

    public func isClosed(): Bool {
        closed.load()
    }

    /** 当前活跃会话数（巡检/用例断言用）。 */
    public func size(): Int64 {
        synchronized(mutex) {
            sessions.size
        }
    }

    /** 巡检：回收已断开的连接（关闭游标、归还 pin 连接）并移出注册表。 */
    func sweep(): Unit {
        if (closed.load()) {
            return
        }
        let stale = ArrayList<DbdSession>()
        synchronized(mutex) {
            let keys = ArrayList<String>()
            for ((key, session) in sessions) {
                let gone = match (session.buffer) {
                    case Some(buffer) => isBufferClosed(buffer)
                    case None => true
                }
                if (gone) {
                    keys.add(key)
                }
            }
            for (key in keys) {
                if (let Some(session) <- sessions.remove(key)) {
                    stale.add(session)
                }
            }
        }
        for (session in stale) {
            logger.debug('reclaiming disconnected session ${session.id}')
            try {
                session.close()
            } catch (e: Exception) {
                logger.warn('failed to reclaim session ${session.id}: ${e.message}')
            }
        }
    }

    private static func isBufferClosed(buffer: SocketBuffer): Bool {
        try {
            buffer.isClosed()
        } catch (_: Exception) {
            true
        }
    }

    private func keyOf(buffer: SocketBuffer): String {
        try {
            buffer.remoteAddress.toString()
        } catch (_: Exception) {
            // 连接已在关闭途中：给一个独立键，避免与正常会话混在一起
            'closed#${anonymous.fetchAdd(1)}'
        }
    }
}
