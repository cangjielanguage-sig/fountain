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
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.SqlPayload
import fountain::f_dbd.exception.DbdException

/**
 * 事务（设计 §5.8）：三个 `mut prop` 按 std 语义可读写，但**只作记录** —— 不会自动转换成方言语句
 * （`begin` / savepoint 透传的是固定的会话控制语句）；需要方言级隔离级别时应在 SQL 文本里显式给出，
 * 由服务端处理。
 *
 * **与结果集互斥**：`begin` / `commit` / `rollback` / savepoint 三兄弟都要发 `SqlPayload`，
 * 因此先过连接级的结果集独占闸门（§7.3 客户端前置约束），否则鬼知道会作用到谁的游标上。
 */
public class DbdTransaction <: Transaction {
    private let connection: DbdConnection
    private let options: DbdOptions
    private var accessModeValue: TransactionAccessMode = Unspecified
    private var deferrableModeValue: TransactionDeferrableMode = Unspecified
    private var isoLevelValue: TransactionIsoLevel = Unspecified
    private var begun: Bool = false

    init(connection: DbdConnection, options: DbdOptions) {
        this.connection = connection
        this.options = options
    }

    public mut prop accessMode: TransactionAccessMode {
        get() {
            accessModeValue
        }
        set(value) {
            accessModeValue = value
        }
    }

    public mut prop deferrableMode: TransactionDeferrableMode {
        get() {
            deferrableModeValue
        }
        set(value) {
            deferrableModeValue = value
        }
    }

    public mut prop isoLevel: TransactionIsoLevel {
        get() {
            isoLevelValue
        }
        set(value) {
            isoLevelValue = value
        }
    }

    /** 独占连接上的下一个时间点：发 `'begin'`；已 begin 再 begin → `TX_STATE`。 */
    public func begin(): Unit {
        if (begun) {
            throw DbdException(DbdErrorCode.TX_STATE, 'the transaction has already begun')
        }
        execute('begin')
        begun = true
    }

    public func commit(): Unit {
        ensureBegun('commit')
        execute('commit')
        begun = false
    }

    public func rollback(): Unit {
        ensureBegun('rollback')
        execute('rollback')
        begun = false
    }

    public func save(savePointName: String): Unit {
        ensureBegun('savepoint')
        check(savePointName)
        execute('savepoint ${savePointName}')
    }

    public func rollback(savePointName: String): Unit {
        ensureBegun('rollback to savepoint')
        check(savePointName)
        execute('rollback to savepoint ${savePointName}')
    }

    public func release(savePointName: String): Unit {
        ensureBegun('release savepoint')
        check(savePointName)
        execute('release savepoint ${savePointName}')
    }

    /** 会话控制语句也是 `SqlPayload`：过独占闸门后按 `query_timeout` 发送。 */
    private func execute(sql: String): Unit {
        connection.ensureNoOpenResult('executing \'${sql}\' while a query result is still open')
        let timeout = match (options.queryTimeout) {
            case Some(t) => t
            case None => NO_TIMEOUT
        }
        connection.request(SqlPayload(sql), timeout)
    }

    private func ensureBegun(action: String): Unit {
        if (!begun) {
            throw DbdException(DbdErrorCode.TX_STATE, 'cannot ${action}: the transaction has not begun')
        }
    }

    /**
     * savepoint 名是**拼进 SQL 文本**的，必须挡注入：只放行 `[A-Za-z_][A-Za-z0-9_]*`，
     * 含空格 / 分号 / 引号等一律 `PROTOCOL`（而不是让它们变成一条合法 SQL 的一部分）。
     */
    private static func check(name: String): Unit {
        if (name.isEmpty() || !isIdentifier(name)) {
            throw DbdException(DbdErrorCode.PROTOCOL, 'illegal savepoint name \'${name}\'')
        }
    }

    private static func isIdentifier(name: String): Bool {
        let runes = name.toRuneArray()
        if (!isStart(runes[0])) {
            return false
        }
        for (r in runes) {
            if (!isPart(r)) {
                return false
            }
        }
        true
    }

    private static func isStart(r: Rune): Bool {
        let c = UInt32(r)
        (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x5f
    }

    private static func isPart(r: Rune): Bool {
        let c = UInt32(r)
        isStart(r) || (c >= 0x30 && c <= 0x39)
    }
}
