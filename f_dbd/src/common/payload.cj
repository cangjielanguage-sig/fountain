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
package fountain::f_dbd.common

import std.database.sql.*
import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * SQL 与 SQL 参数（设计 §3.3）。
 *
 * `params` 字段**必须是 `var`**：写成 `let` 时宏生成的是只读属性（`ReadonlyField`），
 * fdbm 解码 CONSUME 载荷时取不到可变字段 —— 默认 flag 静默丢参数、严格 flag 抛 `DataException`。
 */
@DataAssist[fields props]
public class SqlPayload {
    private var sql: String = ''
    // 类型必须显式写出：`@DataAssist` 的 props 生成需要 `VarDecl.declType`，推断写法会让宏抛 ASTException
    private var params: ArrayList<DataAny> = ArrayList<DataAny>()

    public init() {}

    public init(sql: String) {
        this.sql = sql
    }

    /** 追加一个参数：`params.add(DataAny(param.toData()))`。 */
    public func add<T>(param: T): Unit where T <: ToData {
        params.add(DataAny(param.toData()))
    }

    /** 追加 SQL NULL（对应 `setNull(index)` 或空洞参数）。 */
    public func addNull(): Unit {
        params.add(DataAny(DataNone.INSTANCE))
    }
}

/**
 * 更新类结果（设计 §3.4）：**自身实现 `UpdateResult`**，无适配器类。
 *
 * 数据字段与接口属性分名：`rc` / `liid` 承载数据且可解码（**线上键名就是它们**），
 * `rowCount` / `lastInsertId` 作为只读属性满足接口，并用 `@DataExclude[field]` 排除出序列化。
 */
@DataAssist[fields props]
public class UpdateResultPayload <: UpdateResult {
    private var rc: Int64 = 0
    private var liid: Int64 = 0

    public init() {}

    public init(rowCount: Int64, lastInsertId: Int64) {
        this.rc = rowCount
        this.liid = lastInsertId
    }

    @DataExclude[field]
    public prop rowCount: Int64 {
        get() {
            rc
        }
    }
    @DataExclude[field]
    public prop lastInsertId: Int64 {
        get() {
            liid
        }
    }
}

/**
 * 查询的首包响应（设计 §3.5）：**只有列信息，没有任何行状态**。
 *
 * 2026-10-17 用户拍板：fdbm 执行 `query()` 后不预取任何行，客户端的每次 `next()`（含第一次）
 * 都发 `NEXT_ROW`。因此本类不实现 `QueryResult`——行数据由后续请求按需拉取。
 */
@DataAssist[fields props]
public class QueryResultServerPayload {
    private var columnInfos: Array<ColumnInfoImpl> = []

    public init() {}

    public init(columnInfos: Array<ColumnInfoImpl>) {
        this.columnInfos = columnInfos
    }
}

/**
 * 游标操作（列读 / 推进），设计 §3.6。
 *
 * `index >= 0` 读当前行第 index 列，`NEXT_ROW (-1)` 推进到下一行。
 * **关闭不复用本载荷**：关闭走 `Message.unsubscribe` + `QueryResultClosePayload`（§3.6.1）。
 */
@DataAssist[fields props]
public class QueryResultColumnPayload {
    private var index: Int64 = 0
    private var bufSize: Int64 = 0

    public init() {}

    public init(index: Int64, bufSize!: Int64 = 0) {
        this.index = index
        this.bufSize = bufSize
    }

    public static func cell(index: Int64, bufSize!: Int64 = 0): QueryResultColumnPayload {
        QueryResultColumnPayload(index, bufSize: bufSize)
    }

    public static func nextRow(): QueryResultColumnPayload {
        QueryResultColumnPayload(NEXT_ROW)
    }
}

/**
 * 关闭游标载荷（设计 §3.6.1）。
 *
 * `qid` 是发起查询那条 `CONSUME(SqlPayload)` 的 `MessageID.toString()`（RESP 回带请求 id），
 * 用于显式标识要关闭的结果集；fdbm 未命中时幂等 ACK。
 */
@DataAssist[fields props]
public class QueryResultClosePayload {
    private var qid: String = ''

    public init() {}

    public init(qid: String) {
        this.qid = qid
    }
}
