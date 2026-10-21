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

import std.collection.{ArrayList, HashSet}
import std.database.sql.*
import std.io.InputStream
import std.reflect.TypeInfo
import std.time.DateTime
import fountain::f_data.*
import fountain::f_data.base.*

/**
 * 列读请求的发送器（设计 §3.10）。
 *
 * 把 `QueryResultColumnPayload` 发给 fdbm 并返回响应 `Data`：driver 层注入
 * `p => transport.request(p, queryTimeout).data`（§5.9），用例注入桩。
 */
public type ColumnRequestSender = (QueryResultColumnPayload) -> Data

/** 关闭游标：把 `QueryResultClosePayload`（qid）发出去并等到 ACK；driver 层注入，用例注入桩。 */
public type ResultCloser = (QueryResultClosePayload) -> Unit

/**
 * 结果集（设计 §3.10）：用查询首包 `QueryResultServerPayload`（**仅列信息**）与列读载荷
 * `QueryResultColumnPayload`（列读 / `NEXT_ROW`）实现 `std.database.sql.QueryResult`；
 * 关闭走 `UNSUBSCRIBE(QueryResultClosePayload(qid))` → `ACK`。
 *
 * **无预读、无缓存**：构造期不发请求，行状态一律由 `NEXT_ROW` 取得；`get/getOrNull` 每次都发包
 * （fdbm 用当前行缓冲应答重复请求）。客户端只保留**已打开的流句柄**（规则 1/8 要求的终态与句柄复用）。
 *
 * 类型分派按 §10.1 的实验结论：候选 B（`None<T>` + `match case _: ?X`）+ 接口子类型兜底。
 */
public class QueryResultImpl <: QueryResult {
    /** 查询标识（`qid`）：查询 RESP 的 `Message.id.toString()`，供 `close()` 匹配（§3.6.1、§7.3）。 */
    private let queryId_: String
    private let send_: ColumnRequestSender
    private let closer_: ResultCloser
    private let chunkSize_: Int64
    private let infos_: Array<ColumnInfo>
    /** 当前行已打开的流（按列索引复用句柄：同一行同一列只打开一次，见 `openStreamAsAny`）。 */
    private let streams_: ArrayList<DbdInputStream> = ArrayList<DbdInputStream>()
    /** 本行已探测为 SQL NULL 的流列（避免重复探测）。 */
    private let nullStreams_: HashSet<Int64> = HashSet<Int64>()
    /** 当前行是否可读（最后一次 `next()` 返回 `true`）。 */
    private var rowValid: Bool = false
    /** 结果集是否已耗尽（`next()` 返回过 `false`，终态）。 */
    private var exhausted: Bool = false
    private var closed_: Bool = false

    public init(payload: QueryResultServerPayload, queryId: String, send: ColumnRequestSender,
        closer!: ResultCloser, chunkSize!: Int64 = DEFAULT_STREAM_CHUNK) {
        this.queryId_ = queryId
        this.send_ = send
        this.closer_ = closer
        this.chunkSize_ = if (chunkSize <= 0) { DEFAULT_STREAM_CHUNK } else { chunkSize }
        // `Array<ColumnInfoImpl>` → `Array<ColumnInfo>`：泛型不变，只能逐项转换（§3.4 规则 7）
        let list = ArrayList<ColumnInfo>()
        for (info in payload.columnInfos) {
            list.add(info)
        }
        this.infos_ = list.toArray()
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            infos_
        }
    }

    /**
     * 推进行游标（**无预读**：含第一次在内的每次调用都发 `NEXT_ROW`）。
     *
     * - 响应为 `DataBool`：`true` → 当前行可读；`false` → 结果集耗尽（终态，之后直接返回 `false` 且不再发包）；
     * - 非 `DataBool` → `PROTOCOL`（判别的是线上报文形状，不是数值语义）；
     * - 已 `close()` → `CURSOR_STATE`（**不静默返回 `false`**，规则 2/3）。
     */
    public func next(): Bool {
        if (closed_) {
            throw DbdException(CURSOR_STATE, 'query result ${queryId_} is already closed')
        }
        if (exhausted) {
            return false
        }
        let data = send_(QueryResultColumnPayload.nextRow())
        let has = match (data) {
            case flag: DataBool => flag.data
            case _ => throw DbdException(PROTOCOL, 'NEXT_ROW response is not a DataBool: ${data}')
        }
        // 规则 1：进入新行前，本行已打开但未读完的流立即失效
        invalidateStreams()
        if (has) {
            rowValid = true
        } else {
            exhausted = true
            rowValid = false
        }
        has
    }

    /** deprecated 兼容（完整实现 std API）：忽略 `values`，等价 `next()`。 */
    public func next(values: Array<SqlDbType>): Bool {
        next()
    }

    /**
     * 当前行第 index 列的强类型取值（**可空但精确**，§3.9 B 口径）。
     *
     * 只有 SQL NULL（`DataNone`）返回 `None<T>`；越界 / 带小数 / 不可转换同样抛
     * `DbdException(CONVERSION)`。**每次调用都发一次请求，客户端不缓存**（规则 8）。
     */
    public func getOrNull<T>(index: Int64): ?T {
        ensureReadable(index)
        // G05：流列只能按 InputStream 读；标量目标必须在**发请求之前**失败
        if (isStreamColumn(index) && !isStreamTarget<T>()) {
            throw DbdException(CONVERSION,
                'column ${index} is a stream column; read it as InputStream')
        }
        if (isStreamTarget<T>()) {
            // G04：首次打开时发 `CELL(index, -1)` 探测 NULL；首块作为流的初始缓冲
            let opened = openStreamAsAny(index)
            if (opened is DataNone) {
                return None<T>
            }
            return Some(asTarget<T>(opened, index))
        }
        let data = send_(QueryResultColumnPayload.cell(index))
        if (data is DataNone) {
            return None<T>
        }
        Some(asTarget<T>(decodeCellAsAny<T>(index, data), index))
    }

    /** 把分派产出的值收口成 `T`（装箱 → `case x: T`）；不匹配即 `CONVERSION`（不变量 2）。 */
    private func asTarget<T>(value: Any, index: Int64): T {
        match (value) {
            case x: T => x
            case _ =>
                throw DbdException(CONVERSION,
                    'column ${index} (${infos_[index].typeName}) cannot be read as ${TypeInfo.of<T>()}')
        }
    }

    /**
     * `T` 是否是流（`InputStream`）目标：先走 §10.1 候选 B 的精确匹配，
     * 再补一次子类型判定兜住 `InputStream` 的**实现类**（候选 A 的语义，§10.1 结论 3）。
     */
    private static func isStreamTarget<T>(): Bool {
        let probe: ?T = None<T>
        match (probe) {
            case _: ?InputStream => true
            case _ => TypeInfo.of<T>().isSubtypeOf(DbdTypeInfo.INPUT_STREAM)
        }
    }

    /** 同 `getOrNull<T>`，但 SQL NULL 抛 `DbdException(CONVERSION)`（B 口径：NULL 强取即报错）。 */
    public func get<T>(index: Int64): T {
        match (getOrNull<T>(index)) {
            case Some(x) => x
            case None =>
                throw DbdException(CONVERSION,
                    'column ${index} is NULL; use getOrNull to read it as an Option')
        }
    }

    /**
     * 关闭游标（幂等）：首次调用发 `UNSUBSCRIBE(QueryResultClosePayload(queryId))` 并等 ACK。
     *
     * **无论成功或失败都释放本地状态、失效已打开的流** —— 对端回 `ERROR` 或传输抛异常时一律吞掉
     * （§3.10 规则 7：应用不需要为"关闭失败"再写一遍清理）。第二次调用不再发包。
     */
    public func close(): Unit {
        if (closed_) {
            return
        }
        try {
            closer_(QueryResultClosePayload(queryId_))
        } catch (_: Exception) {
            ()
        }
        closed_ = true
        rowValid = false
        invalidateStreams()
    }

    public func isClosed(): Bool {
        closed_
    }

    /** 状态与边界检查（规则 5/6）。 */

    private func ensureReadable(index: Int64): Unit {
        if (closed_) {
            throw DbdException(CURSOR_STATE, 'query result ${queryId_} is already closed')
        }
        if (!rowValid) {
            throw DbdException(CURSOR_STATE,
                'no current row on query result ${queryId_}: invoke next() before reading columns')
        }
        if (index < 0 || index >= infos_.size) {
            throw DbdException(CONVERSION,
                'column index ${index} is out of range [0, ${infos_.size})')
        }
    }

    /**
     * 类型分派 + 取值（§10.1 结论：候选 B + 接口子类型兜底）。
     *
     * `get<T>` 的 `T` 无编译期约束，`SqlTypes.decode<T>` 又要求 `T <: DataFields<T>`，
     * 故这里先用 `None<T>` 的 `match` 把 `T` 落到**具体**类型分支，再调具体实例化的 `decode`，
     * 最后把结果装箱成 `Any` 交回调用方（调用方用 `case x: T` 完成收口）。
     * `T` 不在表内、或是 `InputStream` 的实现类（B 的精确匹配认不出）时走 `fallbackAsAny`。
     */
    private func decodeCellAsAny<T>(index: Int64, data: Data): Any {
        let probe: ?T = None<T>
        var value: Any = DataNone.INSTANCE
        try {
            value = match (probe) {
                case _: ?String => decoded<String>(data)
                case _: ?Rune => runeOf(data)
                case _: ?Bool => decoded<Bool>(data)
                case _: ?Int8 => decoded<Int8>(data)
                case _: ?Int16 => decoded<Int16>(data)
                case _: ?Int32 => decoded<Int32>(data)
                case _: ?Int64 => decoded<Int64>(data)
                case _: ?UInt8 => decoded<UInt8>(data)
                case _: ?UInt16 => decoded<UInt16>(data)
                case _: ?UInt32 => decoded<UInt32>(data)
                case _: ?UInt64 => decoded<UInt64>(data)
                case _: ?Float32 => decoded<Float32>(data)
                case _: ?Float64 => decoded<Float64>(data)
                case _: ?Decimal => decoded<Decimal>(data)
                case _: ?BigInt => decoded<BigInt>(data)
                case _: ?Array<Byte> => decoded<Array<Byte>>(data)
                case _: ?DateTime => decoded<DateTime>(data)
                case _: ?Duration => decoded<Duration>(data)
                case _ => fallbackAsAny<T>()
            }
        } catch (e: DataException) {
            throw DbdException(CONVERSION,
                'column ${index} cannot be converted: ${e.message}', cause: e)
        } catch (e: OverflowException) {
            throw DbdException(CONVERSION,
                'column ${index} is out of the range of ${TypeInfo.of<T>()}: ${e.message}', cause: e)
        }
        value
    }

    /** 具体实例化地解码一格；`None`（NULL）→ `DataNone.INSTANCE` 交调用方转成 `None<T>`。 */
    private static func decoded<T>(data: Data): Any where T <: DataFields<T> {
        match (SqlTypes.decode<T>(data)) {
            case Some(v) => v
            case None => DataNone.INSTANCE
        }
    }

    /** `Rune` 列按 `String` 传输（§8），取值时还原成单个 `Rune`。 */
    private static func runeOf(data: Data): Any {
        match (SqlTypes.decode<String>(data)) {
            case Some(s) =>
                let runes = s.toRuneArray()
                if (runes.size != 1) {
                    throw DbdException(CONVERSION,
                        'column value \'${s}\' is not a single Rune (${runes.size} runes)')
                }
                runes[0]
            case None => DataNone.INSTANCE
        }
    }

    /**
     * 兜底分支（只在冷路径）：`T` 不在 §8 表内时抛 `CONVERSION`。
     *
     * `InputStream` 的**实现类**不会走到这里 —— 它们由 `isStreamTarget` 的子类型兜底接住，
     * 与候选 A 的行为一致（§10.1 结论 3：「不得仅凭速度选 B」）。
     */
    private static func fallbackAsAny<T>(): Any {
        throw DbdException(CONVERSION, 'unsupported column type ${TypeInfo.of<T>()}')
    }

    /** 该列是否为流列（§8：线上 `typeName` 只可能是这两种仓颉类型名写法）。 */
    private func isStreamColumn(index: Int64): Bool {
        let tn = infos_[index].typeName
        tn == 'InputStream' || tn == 'std.io.InputStream'
    }

    /**
     * 打开（或复用）流列句柄。
     *
     * **同一行同一列只打开一次**：句柄按列索引存在本结果集里，重复 `get<InputStream>` 返回同一个流，
     * 否则两个流会交错消耗服务端那一个物理流（`fdbm` 的当前行缓冲缓存的就是句柄，见 D3）。
     * 行切换与 `close()` 时统一失效（规则 1）。
     */
    private func openStreamAsAny(index: Int64): Any {
        if (!isStreamColumn(index)) {
            throw DbdException(CONVERSION,
                'column ${index} is ${infos_[index].typeName}, not a stream column')
        }
        for (stream in streams_) {
            if (stream.columnIndex == index) {
                return stream
            }
        }
        if (nullStreams_.contains(index)) {
            return DataNone.INSTANCE
        }
        // `bufSize = -1` 是 NULL 探测的保留值：服务端回 `DataNone` 表示 SQL NULL
        let probe = send_(QueryResultColumnPayload.cell(index, bufSize: -1))
        if (probe is DataNone) {
            nullStreams_.add(index)
            return DataNone.INSTANCE
        }
        let initial = try {
            match (SqlTypes.decode<Array<Byte>>(probe)) {
                case Some(bytes) => bytes
                case None => throw DbdException(CONVERSION,
                    'stream probe of column ${index} is not a byte array')
            }
        } catch (e: DataException) {
            throw DbdException(CONVERSION,
                'stream probe of column ${index} cannot be decoded: ${e.message}', cause: e)
        } catch (e: Exception) {
            throw DbdException(CONVERSION,
                'stream probe of column ${index} is not a byte array: ${e.message}', cause: e)
        }
        let stream = DbdInputStream(this, index, chunkSize_, initial: initial)
        streams_.add(stream)
        stream
    }

    /** 规则 1：本行已打开的流全部失效（进入新行 / 关闭结果集时调用）。 */
    private func invalidateStreams(): Unit {
        for (stream in streams_) {
            stream.invalidate()
        }
        streams_.clear()
        nullStreams_.clear()
    }

    /** 供 `DbdInputStream` 发块请求：`CELL(index, bufSize)` → 字节块（空数组表示 EOF）。 */
    func requestBlock(index: Int64, bufSize: Int64): Array<Byte> {
        if (closed_) {
            throw DbdException(CURSOR_STATE, 'query result ${queryId_} is already closed')
        }
        let data = send_(QueryResultColumnPayload.cell(index, bufSize: bufSize))
        if (data is DataNone) {
            return Array<Byte>()
        }
        try {
            match (SqlTypes.decode<Array<Byte>>(data)) {
                case Some(bytes) => bytes
                case None => throw DbdException(CONVERSION,
                    'stream block of column ${index} is not a byte array')
            }
        } catch (e: DataException) {
            throw DbdException(CONVERSION, 'stream block of column ${index} cannot be decoded: ${e.message}',
                cause: e)
        } catch (e: OverflowException) {
            throw DbdException(CONVERSION, 'stream block of column ${index} is out of range: ${e.message}',
                cause: e)
        } catch (e: Exception) {
            throw DbdException(CONVERSION, 'stream block of column ${index} is not a byte array: ${e.message}',
                cause: e)
        }
    }
}

/**
 * 流列的分块读（设计 §3.11）。
 *
 * **不预读**：本地块只保存"上一次块响应中尚未消费完的字节"，块耗尽后下一次 `read` 才发新的块请求；
 * 服务端返回空数组即 EOF（终态，之后不再发包）。所属结果集 `close()` 或本行失效后再 `read`
 * 抛 `DbdException(CURSOR_STATE)`。
 */
public class DbdInputStream <: InputStream {
    /** 所属结果集。 */
    private let owner: QueryResultImpl
    /** 列索引（包内可读，供 `QueryResultImpl` 按列复用句柄）。 */
    let columnIndex: Int64
    private let chunkSize: Int64
    /** 上次块响应中尚未消费完的字节。 */
    private var pending: Array<Byte> = Array<Byte>()
    private var pos: Int64 = 0
    private var eof: Bool = false
    private var dead: Bool = false

    init(owner: QueryResultImpl, columnIndex: Int64, chunkSize: Int64,
        initial!: Array<Byte> = []) {
        this.owner = owner
        this.columnIndex = columnIndex
        this.chunkSize = chunkSize
        this.pending = initial
    }

    /**
     * 读一块：优先消费本地块；块空则发一次 `CELL(columnIndex, chunkSize)`。
     *
     * @return 读入的字节数；**0 表示流结束**（空 buffer 或 EOF）。
     */
    public func read(buffer: Array<Byte>): Int64 {
        if (dead || owner.isClosed()) {
            throw DbdException(CURSOR_STATE,
                'the stream of column ${columnIndex} is no longer valid: the row has been advanced or the result set is closed')
        }
        if (buffer.isEmpty() || eof) {
            return 0
        }
        if (pos >= pending.size) {
            pending = owner.requestBlock(columnIndex, chunkSize)
            pos = 0
            if (pending.isEmpty()) {
                eof = true
                return 0
            }
        }
        let n = if (buffer.size < pending.size - pos) { buffer.size } else { pending.size - pos }
        var i: Int64 = 0
        while (i < n) {
            buffer[i] = pending[pos + i]
            i += 1
        }
        pos += n
        n
    }

    /** 规则 1：所属结果集进入新行 / 关闭时调用，之后 `read` 抛 `CURSOR_STATE`。 */
    func invalidate(): Unit {
        dead = true
        pending = Array<Byte>()
        pos = 0
    }
}

/** §10.1 接口兜底用到的 `TypeInfo` 常量（热路径不构造，只在 `fallbackAsAny` 用一次）。 */
private struct DbdTypeInfo {
    static let INPUT_STREAM = TypeInfo.of<InputStream>()
}
