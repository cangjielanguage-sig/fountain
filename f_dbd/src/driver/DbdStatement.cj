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

import std.collection.HashMap
import std.database.sql.*
import std.io.InputStream
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_data.{Data, DataAny, DataException, DataNone}
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.{ColumnRequestSender, QueryResultClosePayload, QueryResultImpl,
    QueryResultServerPayload, ResultCloser, SqlPayload, SqlTypes, UpdateResultPayload, decodeStrict}
import fountain::f_dbd.exception.DbdException

/**
 * 语句（设计 §5.5）：参数由 `set(index, value)` 按 **0 起** 的 index 收集，执行时按 `0..max` 组装
 * （跳过的位置编码成 `DataNone`）；发 `SqlPayload` 之前一律先过连接级的结果集独占闸门。
 *
 * Statement 只是**本地句柄**：同一连接上可以有多个 Statement 并存，
 * `prepareStatement` / `set` / `setNull` / `close` 都不发任何报文。
 */
public class DbdStatement <: Statement {
    private let connection: DbdConnection
    private let sql: String
    private let options: DbdOptions
    /** index → 已编码的参数；执行时按 `0..max` 取出，缺的位置补 `DataNone`。 */
    private let parameters = HashMap<Int64, Data>()
    private var openResult: ?QueryResultImpl = None
    private var closed: Bool = false

    init(connection: DbdConnection, sql: String, options: DbdOptions) {
        this.connection = connection
        this.sql = sql
        this.options = options
    }

    /** 恒为空数组：fdbm 不提供服务端参数元数据，参数由 `?` 的位置确定。 */
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            Array<ColumnInfo>()
        }
    }

    /**
     * 按 index 记录一个参数（**0 起**）；同一个 index 重复设值以最后一次为准。
     *
     * 不支持的类型（`SqlTypes.encodeParameter` 抛 `DataException`）统一包成 `DbdException(CONVERSION)`，
     * 以保持"对外只抛 `SqlException`"的契约。
     */
    public func set<T>(index: Int64, value: T): Unit {
        checkIndex(index)
        parameters[index] = encode<T>(index, value)
    }

    /** 记录 SQL NULL（`DataNone`）。 */
    public func setNull(index: Int64): Unit {
        checkIndex(index)
        parameters[index] = DataNone.INSTANCE
    }

    /**
     * 执行查询：期望 RESP 为查询首包 `QueryResultServerPayload`（**只含列信息**）。
     *
     * 拿到的 `Message.id.toString()` 就是 qid，连同两个发送器一起交给 `QueryResultImpl`（§5.6）——
     * driver 层在这一步完成"注入真实传输"，结果集状态机本身已在 common 用桩测完。
     * 成功后把结果集登记到连接上（此后该连接被它独占）。
     */
    public func query(): QueryResult {
        ensureExecutable()
        let timeout = timeoutOf(options.queryTimeout)
        let answer = connection.request(sqlPayload(), timeout)
        let first = match (decodeStrict<QueryResultServerPayload>(answer.data)) {
            case Some(p) => p
            case None => throw DbdException(DbdErrorCode.PROTOCOL,
                'the response of \'${sql}\' is not a query result header')
        }
        let sender: ColumnRequestSender = {request => connection.request(request, timeout).data}
        let closer: ResultCloser = {request => connection.unsubscribe(request, timeout)}
        let result = QueryResultImpl(first, answer.id.toString(), sender, closer: closer,
            chunkSize: options.fetchRows)
        openResult = result
        connection.registerResult(result)
        result
    }

    /**
     * 执行更新：期望 RESP 为 `UpdateResultPayload`，它自身实现 `UpdateResult`，直接返回（无适配器）。
     * 服务端 ERROR 由传输层还原成 `DbdException` 抛出，连接保持可用。
     */
    public func update(): UpdateResult {
        ensureExecutable()
        let timeout = timeoutOf(options.updateTimeout)
        let answer = connection.request(sqlPayload(), timeout)
        match (decodeStrict<UpdateResultPayload>(answer.data)) {
            case Some(r) => r
            case None => throw DbdException(DbdErrorCode.PROTOCOL,
                'the response of \'${sql}\' is not an update result')
        }
    }

    /** 写入语句级选项（`query_timeout` / `update_timeout` / `fetch_rows`），覆盖连接级。 */
    public func setOption(key: String, value: String): Unit {
        options.apply(key, value)
    }

    /** 幂等：产生过游标则先关闭它（对端失败被吞，本地一定关掉）。 */
    public func close(): Unit {
        if (let Some(r) <- openResult) {
            try {
                r.close()
            } catch (_: Exception) {
                ()
            }
            openResult = None
        }
        parameters.clear()
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }

    /** deprecated 兼容：按数组顺序逐个 `set` 后走无参版本。 */
    public func query(params: Array<SqlDbType>): QueryResult {
        bind(params)
        query()
    }

    /** deprecated 兼容：同上。 */
    public func update(params: Array<SqlDbType>): UpdateResult {
        bind(params)
        update()
    }

    private func ensureExecutable(): Unit {
        if (closed) {
            throw DbdException(DbdErrorCode.CURSOR_STATE, 'the statement of \'${sql}\' is closed')
        }
        connection.ensureNoOpenResult('executing another statement on this connection')
    }

    /** 参数组装：缺的位置（空洞）补 `DataNone`，保持与 `?` 的位置一一对应。 */
    private func sqlPayload(): SqlPayload {
        let payload = SqlPayload(sql)
        var max: Int64 = -1
        for ((index, _) in parameters) {
            if (index > max) {
                max = index
            }
        }
        var i: Int64 = 0
        while (i <= max) {
            match (parameters.get(i)) {
                case Some(data) => payload.add<DataAny>(DataAny(data))
                case None => payload.addNull()
            }
            i += 1
        }
        payload
    }

    private static func timeoutOf(configured: ?Duration): Duration {
        match (configured) {
            case Some(t) => t
            case None => NO_TIMEOUT
        }
    }

    private static func checkIndex(index: Int64): Unit {
        if (index < 0) {
            throw DbdException(DbdErrorCode.CONVERSION, 'parameter index ${index} must not be negative')
        }
    }

    private func bind(params: Array<SqlDbType>): Unit {
        var i: Int64 = 0
        for (p in params) {
            setSqlDbType(i, p)
            i += 1
        }
    }

    private static func encode<T>(index: Int64, value: T): Data {
        try {
            SqlTypes.encodeParameter<T>(value)
        } catch (e: DataException) {
            throw DbdException(DbdErrorCode.CONVERSION,
                'parameter ${index} cannot be encoded: ${e.message}', cause: e)
        }
    }

    /**
     * deprecated 参数（`SqlDbType`）：接口只暴露 `name`，数值藏在具体实现的 `value` 里，
     * 只能逐个 `match` 到具体类再取值（`SqlNullable*` 的 `value == None` → `setNull`）。
     */
    private func setSqlDbType(index: Int64, value: SqlDbType): Unit {
        match (value) {
            case v: SqlBigInt => set<Int64>(index, v.value)
            case v: SqlBinary => set<Array<Byte>>(index, v.value)
            case v: SqlBlob => set<InputStream>(index, v.value)
            case v: SqlBool => set<Bool>(index, v.value)
            case v: SqlByte => set<Int8>(index, v.value)
            case v: SqlChar => set<String>(index, v.value)
            case v: SqlClob => set<InputStream>(index, v.value)
            case v: SqlDate => set<DateTime>(index, v.value)
            case v: SqlDecimal => set<Decimal>(index, v.value)
            case v: SqlDouble => set<Float64>(index, v.value)
            case v: SqlInteger => set<Int32>(index, v.value)
            case v: SqlInterval => set<Duration>(index, v.value)
            case v: SqlReal => set<Float32>(index, v.value)
            case v: SqlSmallInt => set<Int16>(index, v.value)
            case v: SqlTime => set<DateTime>(index, v.value)
            case v: SqlTimestamp => set<DateTime>(index, v.value)
            case v: SqlTimeTz => set<DateTime>(index, v.value)
            case v: SqlVarBinary => set<Array<Byte>>(index, v.value)
            case v: SqlVarchar => set<String>(index, v.value)
            case v: SqlNullableBigInt => setNullable<Int64>(index, v.value)
            case v: SqlNullableBinary => setNullable<Array<Byte>>(index, v.value)
            case v: SqlNullableBlob => setNullable<InputStream>(index, v.value)
            case v: SqlNullableBool => setNullable<Bool>(index, v.value)
            case v: SqlNullableByte => setNullable<Int8>(index, v.value)
            case v: SqlNullableChar => setNullable<String>(index, v.value)
            case v: SqlNullableClob => setNullable<InputStream>(index, v.value)
            case v: SqlNullableDate => setNullable<DateTime>(index, v.value)
            case v: SqlNullableDecimal => setNullable<Decimal>(index, v.value)
            case v: SqlNullableDouble => setNullable<Float64>(index, v.value)
            case v: SqlNullableInteger => setNullable<Int32>(index, v.value)
            case v: SqlNullableInterval => setNullable<Duration>(index, v.value)
            case v: SqlNullableReal => setNullable<Float32>(index, v.value)
            case v: SqlNullableSmallInt => setNullable<Int16>(index, v.value)
            case v: SqlNullableTime => setNullable<DateTime>(index, v.value)
            case v: SqlNullableTimestamp => setNullable<DateTime>(index, v.value)
            case v: SqlNullableTimeTz => setNullable<DateTime>(index, v.value)
            case v: SqlNullableVarBinary => setNullable<Array<Byte>>(index, v.value)
            case v: SqlNullableVarchar => setNullable<String>(index, v.value)
            case _ => throw DbdException(DbdErrorCode.CONVERSION,
                'unsupported deprecated parameter type: ${value.name}')
        }
    }

    private func setNullable<T>(index: Int64, value: ?T): Unit {
        match (value) {
            case Some(v) => set<T>(index, v)
            case None => setNull(index)
        }
    }
}
