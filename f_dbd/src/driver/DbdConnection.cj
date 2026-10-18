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
package fountain::f_dbd.driver

import std.collection.{HashMap, Map}
import std.database.sql.*
import std.sync.Mutex
import fountain::f_data.ToData
import fountain::f_protocol.default.Message
import fountain::f_version.FountainVersion
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.{QueryResultClosePayload, QueryResultImpl}
import fountain::f_dbd.exception.DbdException

/**
 * 一条到 fdbm 的连接（设计 §5.4）：独占一条 TCP（`DbdTransport`），
 * 承载 `prepareStatement` / `createTransaction` / 会话内的全部请求。
 *
 * **连接级结果集独占**（不变量 6）：同一时刻连接上至多一个未关闭的 `QueryResult`；在它 `close()`
 * 之前，`Statement` 的 `query/update` 与事务 SQL 方法一律 `CURSOR_STATE` 且不发包 —— 因为
 * `QueryResultColumnPayload` **不带结果标识**，放任并发会让旧结果集的 `next/get` 静默作用到新游标上。
 */
public class DbdConnection <: Connection {
    private let url: DbdUrl
    private let transport: DbdTransport
    private let options: DbdOptions
    private let lock = Mutex()
    private var closed: Bool = false
    /** 连接上当前打开的结果集（未关闭即占用本连接）。 */
    private var activeResult: ?QueryResultImpl = None

    init(url: DbdUrl, transport: DbdTransport, options: DbdOptions) {
        this.url = url
        this.transport = transport
        this.options = options
    }

    public prop state: ConnectionState {
        get() {
            synchronized(lock) {
                if (closed) {
                    Closed
                } else if (transport.isClosed()) {
                    Broken
                } else {
                    Connected
                }
            }
        }
    }

    public func prepareStatement(sql: String): Statement {
        if (sql.isEmpty()) {
            throw DbdException(DbdErrorCode.PROTOCOL, 'empty sql is not executable')
        }
        DbdStatement(this, sql, options.copy())
    }

    public func createTransaction(): Transaction {
        DbdTransaction(this, options.copy())
    }

    /**
     * 元信息：`driver` / `version` / `url` / `user` / `database`。
     *
     * **密码绝不出现**：`url` 走 `DbdUrl.toUrlMasked()`（整体换成 `***`），避免 metadata 被打印/上报时泄密。
     */
    public func getMetaData(): Map<String, String> {
        let meta = HashMap<String, String>()
        meta.add('driver', 'fdbm')
        meta.add('version', FountainVersion)
        meta.add('url', url.toUrlMasked())
        meta.add('user', url.user)
        meta.add('database', url.database)
        meta.add('host', url.host)
        meta.add('port', '${url.port}')
        meta
    }

    /**
     * 幂等关闭：先（尽最大努力）关闭未关闭的结果集 —— `QueryResultImpl.close()` 自身幂等且吞掉
     * 对端失败 —— 再关闭传输层并置 `Closed`。
     */
    public func close(): Unit {
        let pending = synchronized(lock) {
            closed = true
            activeResult
        }
        if (let Some(r) <- pending) {
            try {
                r.close()
            } catch (_: Exception) {
                ()
            }
        }
        synchronized(lock) {
            activeResult = None
        }
        transport.close()
    }

    public func isClosed(): Bool {
        state == Closed || transport.isClosed()
    }

    /**
     * 发一个新的 `SqlPayload` 之前的闸门：`Statement` 的 `query/update` 与事务 SQL 方法都要先过这里。
     *
     * 已关闭的结果集会被顺手清掉（因为该结果集不再占用连接）；未关闭的直接拒绝。
     */
    func ensureNoOpenResult(action: String): Unit {
        synchronized(lock) {
            if (let Some(r) <- activeResult) {
                if (r.isClosed()) {
                    activeResult = None
                } else {
                    throw DbdException(DbdErrorCode.CURSOR_STATE,
                        'a query result is still open on this connection: close it before ${action}')
                }
            }
        }
    }

    /** 登记连接上的当前游标（`DbdStatement.query()` 成功后调用）。 */
    func registerResult(result: QueryResultImpl): Unit {
        synchronized(lock) {
            activeResult = result
        }
    }

    /** 结果集专用的收发通道接入点（`QueryResultImpl` 的 `send` / `closer` 由此注入）。 */
    func request<T>(payload: T, timeout: Duration): Message where T <: ToData {
        transport.request(payload, timeout)
    }

    func unsubscribe(payload: QueryResultClosePayload, timeout: Duration): Unit {
        transport.unsubscribe(payload, timeout)
    }
}
