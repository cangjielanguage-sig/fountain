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

import std.database.sql.*
import std.sync.AtomicBool
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.exception.DbdException

/**
 * 单节点数据源（设计 §5.3）：保存 URL 与选项，**`connect()` 才建立连接**（`open()` 不产生 IO）。
 *
 * 每次 `connect()` 产出一条独占 TCP 的 `DbdConnection`（对应一个 `f_net.Client`），
 * 关闭本 Datasource 不影响已建连接（各自持有自己的 Client）。
 */
public class DbdDatasource <: Datasource {
    private let url: DbdUrl
    private let options: DbdOptions = DbdOptions()
    private let closed = AtomicBool(false)

    public init(url: DbdUrl, opts!: Array<(String, String)> = []) {
        this.url = url
        for ((k, v) in opts) {
            this.options.apply(k, v)
        }
    }

    /** 可见的范围：URL 里的凭据可被选项覆盖（`username` / `password`）。 */
    func credential(): DbdUrl {
        let user = if (options.user.isEmpty()) { url.user } else { options.user }
        let password = if (options.password.isEmpty()) { url.password } else { options.password }
        url.withCredentials(user, password)
    }

    /**
     * 建立一条到 fdbm 的连接。
     *
     * - 建链失败（`DbdTransport` 构造时的 socket 异常）→ `DbdException(IO)`；
     * - 配了 `connection_timeout` 时把它用作首次 PING 的等待上限，超时 → `TIMEOUT`；
     * - 本 Datasource 已 `close()` 后再调用 → `DbdException(CONFIG)`。
     */
    public func connect(): Connection {
        if (closed.load()) {
            throw DbdException(DbdErrorCode.CONFIG, 'the fdbm datasource is closed')
        }
        let target = credential()
        let transport = try {
            DbdTransport(target.host, target.port)
        } catch (e: Exception) {
            throw DbdException(DbdErrorCode.IO, 'cannot connect to fdbm at ${target.host}:${target.port}: ${e.message}',
                cause: e)
        }
        try {
            if (let Some(t) <- options.connectionTimeout) {
                transport.ping(t)
            }
        } catch (e: DbdException) {
            transport.close()
            throw e
        } catch (e: Exception) {
            transport.close()
            throw DbdException(DbdErrorCode.IO, 'handshake with fdbm failed: ${e.message}', cause: e)
        }
        DbdConnection(target, transport, options.copy())
    }

    /**
     * 写入选项表（`username` / `password` / `connection_timeout` / `query_timeout` /
     * `update_timeout` / `fetch_rows`）；未识别的 key 忽略并记 DEBUG。
     *
     * 只在**下次 `connect()`** 生效：已经建好的连接各自持有一份拷贝。
     */
    public func setOption(key: String, value: String): Unit {
        options.apply(key, value)
    }

    /** 幂等；已建连接不受影响（各自持有 Client）。 */
    public func close(): Unit {
        closed.store(true)
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
