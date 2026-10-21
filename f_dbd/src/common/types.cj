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
import std.io.{ByteBuffer, InputStream}
import std.math.numeric.Decimal
import std.reflect.TypeInfo
import std.time.DateTime
import fountain::f_base.*
import fountain::f_data.*
import fountain::f_log.LoggerFactory

/** 列读请求的控制哨兵：推进到下一行（响应为 `DataBool`：true=有新行）。 */
public const NEXT_ROW: Int64 = -1
/** URL 未指定端口时的默认端口。 */
public const DEFAULT_PORT: UInt16 = 8112
/** 流列分块的默认块大小（64 KiB）：`bufSize <= 0` 时使用；`fetch_rows` 的默认值也取它。 */
public const DEFAULT_STREAM_CHUNK: Int64 = 65536
/**
 * 单元格（标量）读取的转换标志（B 口径：越界即报错）。
 *
 * 刻意**不含** `WRAPPING_ON_INT_OVERFLOW`（否则窄类型读宽列会静默回绕）与
 * `IGNORE_FIELD_NOT_CONVERTABLE`（该位会把越界静默变成 `None`，使 `THROWING` 根本轮不到）；
 * `IGNORE_FIELD_NOT_FOUND` / `IGNORE_NONE` 只服务对象字段填充，与标量转换无关，故不保留。
 */
public const CELL_READ_FLAG: DataConversionFlag = THROWING_ON_INT_OVERFLOW | IGNORE_FIELD_TYPE_NOT_MATCH

/**
 * 严格解码：保留溢出策略位、去掉全部 `IGNORE_*` 位（flag = `DEFAULT_DATA_FLAG & !SILENCE`）时，
 * 字段缺失 / 类型不匹配 / 无法转换都会抛 `DataException`。
 *
 * 用于区分"同一条 CONSUME 上承载的多种载荷"（`SqlPayload` / `QueryResultColumnPayload` / 各响应类型）：
 * 宽松解码（含 `SILENCE`）会把异构载荷转成"字段为空的同形对象"。
 *
 * **为什么不能取 `flag: 0`**：`f_data` 的整数解码要求四个溢出策略位之一被置位才肯把 `DataReal`
 * 转成 `Int64` 等类型，`flag: 0` 时**所有含整数字段的载荷都解不出来**。
 */
public func decodeStrict<T>(data: Data): ?T where T <: DataFields<T> {
    try {
        convert<T>(data, flag: DEFAULT_DATA_FLAG & !SILENCE)
    } catch (_: DataException) {
        None<T>
    }
}

/**
 * 物理/线上 `typeName` 归一化后的读取类型（设计 §3.9）。
 *
 * 与 `SqlTypes.canonicalName` 的输出一一对应：`canonicalName` 给出仓颉类型名，本枚举给出读取分支。
 *
 * **命名偏差（2026-10-17 实测登记）**：仓颉的 `enum` 构造器**不能**用基础类型关键字
 * （`| Int8` 报 `expected a enum value name after '|'`），且构造器名 `String` 会遮蔽 `String` 类型本身
 * （enum 体内再写 `String` 会报 `'String' is not a type`）。故整数/浮点构造器改名为 `I8/I16/I32/I64`、
 * `U8/U16/U32/U64`、`F32/F64`，`String` 改名为 `Text`；`toString()` 仍返回设计表中的原名字。
 */
public enum SqlReadType <: Equatable<SqlReadType> & ToString {
    | Boolean | I8 | I16 | I32 | I64 | U8 | U16 | U32 | U64
    | F32 | F64 | Decimal | BigInt | Text | Bytes | DateTime | Duration
    | Stream      // InputStream 列
    | Unknown

    public func toString(): String {
        match (this) {
            case Boolean => 'Boolean'
            case I8 => 'Int8'
            case I16 => 'Int16'
            case I32 => 'Int32'
            case I64 => 'Int64'
            case U8 => 'UInt8'
            case U16 => 'UInt16'
            case U32 => 'UInt32'
            case U64 => 'UInt64'
            case F32 => 'Float32'
            case F64 => 'Float64'
            case Decimal => 'Decimal'
            case BigInt => 'BigInt'
            case Text => 'String'
            case Bytes => 'Bytes'
            case DateTime => 'DateTime'
            case Duration => 'Duration'
            case Stream => 'Stream'
            case Unknown => 'Unknown'
        }
    }

    public operator func ==(other: SqlReadType): Bool {
        this.toString() == other.toString()
    }

    /** 仓颉类型名 → 读取类型；未知 → `Unknown`。 */
    public static func of(canonical: String): SqlReadType {
        match (canonical) {
            case 'Bool' => Boolean
            case 'Int8' => I8
            case 'Int16' => I16
            case 'Int32' => I32
            case 'Int64' => I64
            case 'UInt8' => U8
            case 'UInt16' => U16
            case 'UInt32' => U32
            case 'UInt64' => U64
            case 'Float32' => F32
            case 'Float64' => F64
            case 'Decimal' => Decimal
            case 'BigInt' => BigInt
            case 'String' => Text
            case 'Array<Byte>' => Bytes
            case 'std.io.InputStream' => Stream
            case 'DateTime' => DateTime
            case 'Duration' => Duration
            case _ => Unknown
        }
    }
}

/**
 * 类型映射与数值转换（设计 §3.9）。
 *
 * 职责边界：`readType` / `canonicalName` / `readData` / `readStream` / `readChunk` 由 **fdbm** 调用
 * （只有它接触物理驱动）；`encodeParameter` / `decode` 由 **f_dbd** 调用。
 *
 * 识别与归一表见 `fdbm/doc/详细设计.md` §9.6（表放 fdbm 文档，实现放本结构体，避免两端各写一份）。
 */
public struct SqlTypes {
    private static let logger = LoggerFactory.getLogger('fountain::f_dbd.common.SqlTypes')

    /** 物理驱动的任意 `typeName` → 读取类型；未知 → `Unknown`。 */
    public static func readType(typeName: String): SqlReadType {
        match (resolve(typeName)) {
            case Some(name) => SqlReadType.of(name)
            case _ => SqlReadType.Unknown
        }
    }

    /**
     * 归一成仓颉类型名；未知 → `String` 并记 WARN（原始 `typeName` 入日志）。
     *
     * `InputStream` **只由驱动自报产生**：方言大对象名（`bytea` / `*BLOB`）一律归一成 `Array<Byte>`，
     * 不猜驱动能力（fdbm §9.6、设计 §8）。
     */
    public static func canonicalName(typeName: String): String {
        match (resolve(typeName)) {
            case Some(name) => name
            case _ =>
                logger.warn('unknown column typeName \'${typeName}\', falling back to String')
                'String'
        }
    }

    /**
     * 归一化的唯一入口：命中返回仓颉类型名，未命中返回 `None`（交由调用方决定兜底语义）。
     *
     * 判定顺序（fdbm §9.6）：① `Sql*` 抽象名（含 `SqlNullable*` 变体）→ ② `TINYINT(1)` 特例 →
     * ③ 仓颉类型名 → ④ 方言拼写 → ⑤ `... unsigned` → ⑥ 去长度/精度后缀 `(...)` 后重试 →
     * ⑦ 前缀匹配（`varchar2` / `character…`）→ ⑧ 未命中。
     */
    private static func resolve(typeName: String): ?String {
        // `BigInt` 既是仓颉类型名、又是 MySQL 方言 `BIGINT`（前者要 BigInt，后者要 Int64，fdbm §9.6）。
        // 两者只能靠大小写区分：仓颉类型名的拼写是 `BigInt`，SQL 方言一律全大写/全小写。
        let trimmed = typeName.trimAscii()
        if (trimmed == 'BigInt') {
            return Some('BigInt')
        }
        let key = trimmed.toAsciiLower()
        if (key.isEmpty()) {
            return None<String>
        }
        if (key.startsWith('sql')) {
            return resolveSqlName(key.replace('nullable', ''))
        }
        // `TINYINT(1)` 是 Bool，必须在"去括号后缀"之前判定
        if (key == 'tinyint(1)') {
            return Some('Bool')
        }
        match (resolveCangjieName(key)) {
            case Some(n) => return Some(n)
            case _ => ()
        }
        match (resolveDialect(key)) {
            case Some(n) => return Some(n)
            case _ => ()
        }
        // `X unsigned` / `X(n) unsigned`
        if (key.endsWith(' unsigned')) {
            let base = key.removeSuffix(' unsigned').trimAscii()
            match (resolveUnsigned(base)) {
                case Some(n) => return Some(n)
                case _ => ()
            }
            match (parenBaseOf(base)) {
                case Some(b) =>
                    match (resolveUnsigned(b)) {
                        case Some(n) => return Some(n)
                        case _ => ()
                    }
                case _ => ()
            }
        }
        // 去长度/精度后缀：`varchar(64)` / `decimal(10,2)` / `TINYINT(2)`
        if (key.contains('(')) {
            match (parenBaseOf(key)) {
                case Some(b) =>
                    match (resolveCangjieName(b)) {
                        case Some(n) => return Some(n)
                        case _ => ()
                    }
                    match (resolveDialect(b)) {
                        case Some(n) => return Some(n)
                        case _ => ()
                    }
                case _ => ()
            }
        }
        // 前缀匹配：`varchar2` / `nvarchar2` / `character…`
        if (key.startsWith('varchar') || key.startsWith('nvarchar') || key.startsWith('character')) {
            return Some('String')
        }
        None<String>
    }

    /**
     * 带 `(...)` 的拼写：按"最长优先"匹配已知基名并返回基名本身。
     *
     * 仓颉 `String` 没有切片/子串 API（`indexOf` 返回 `?Int64` 且无 `substring`），
     * 故用"已知基名 + `startsWith`"代替"截到左括号"。
     */
    private static func parenBaseOf(key: String): ?String {
        for (b in PAREN_BASES) {
            if (key.startsWith(b)) {
                return Some(b)
            }
        }
        None<String>
    }

    private static let PAREN_BASES: Array<String> = [
        'timestamp with time zone', 'character varying', 'double precision', 'longblob', 'mediumblob',
        'tinyblob', 'longtext', 'mediumtext', 'tinytext', 'nvarchar', 'varbinary', 'mediumint',
        'smallint', 'tinyint', 'bigint', 'integer', 'varchar', 'decimal', 'numeric', 'datetime',
        'timestamp', 'varbit', 'binary', 'double', 'bpchar', 'bytea', 'float', 'blob', 'jsonb',
        'text', 'char', 'time', 'enum', 'year', 'bit', 'set', 'xml', 'json', 'uuid'
    ]

    /** `Sql*` 抽象名（已去掉 `Nullable` 段）。 */
    private static func resolveSqlName(key: String): ?String {
        match (key) {
            case 'sqlchar' | 'sqlvarchar' | 'sqlclob' => Some('String')
            case 'sqlbinary' | 'sqlvarbinary' | 'sqlblob' => Some('Array<Byte>')
            case 'sqldecimal' => Some('Decimal')
            case 'sqlbool' => Some('Bool')
            case 'sqlbyte' => Some('Int8')
            case 'sqlsmallint' => Some('Int16')
            case 'sqlinteger' => Some('Int32')
            case 'sqlbigint' => Some('Int64')
            case 'sqlreal' => Some('Float32')
            case 'sqldouble' => Some('Float64')
            case 'sqldate' | 'sqltime' | 'sqltimetz' | 'sqltimestamp' => Some('DateTime')
            case 'sqlinterval' => Some('Duration')
            case _ => None<String>
        }
    }

    /** 仓颉类型名：原样通过（`Byte` ≡ `UInt8`、带包名前缀形式等价）。 */
    private static func resolveCangjieName(key: String): ?String {
        match (key) {
            case 'string' => Some('String')
            case 'rune' => Some('String')
            case 'bool' => Some('Bool')
            case 'int8' => Some('Int8')
            case 'int16' => Some('Int16')
            case 'int32' => Some('Int32')
            case 'int64' | 'intnative' => Some('Int64')
            case 'uint8' | 'byte' => Some('UInt8')
            case 'uint16' => Some('UInt16')
            case 'uint32' => Some('UInt32')
            case 'uint64' | 'uintnative' => Some('UInt64')
            case 'float32' => Some('Float32')
            case 'float64' => Some('Float64')
            case 'decimal' | 'std.math.numeric.decimal' => Some('Decimal')
            case 'array<byte>' | 'array<uint8>' => Some('Array<Byte>')
            case 'inputstream' | 'std.io.inputstream' => Some('std.io.InputStream')
            case 'datetime' | 'std.time.datetime' => Some('DateTime')
            case 'duration' => Some('Duration')
            case _ => None<String>
        }
    }

    /** 带 `UNSIGNED` 的整型 → 对应 `UInt*`。 */
    private static func resolveUnsigned(base: String): ?String {
        match (base) {
            case 'tinyint' => Some('UInt8')
            case 'smallint' => Some('UInt16')
            case 'mediumint' | 'int' | 'integer' => Some('UInt32')
            case 'bigint' => Some('UInt64')
            case _ => None<String>
        }
    }

    /**
     * 方言拼写（PostgreSQL / openGauss 与 MySQL / MariaDB）。
     *
     * 冲突登记：`bit` 在 PG 表里归 `Array<Byte>`、在 MySQL 表里归 `Bool`（fdbm §9.6 两行同名）。
     * fdbm 一次只加载一个物理驱动、无法按驱动名分派，故取 PG 口径 `Array<Byte>`；
     * MySQL 的布尔语义由 `bool` / `boolean` 覆盖。
     */
    private static func resolveDialect(key: String): ?String {
        match (key) {
            case 'bool' | 'boolean' => Some('Bool')
            case 'int2' | 'smallint' => Some('Int16')
            case 'int4' | 'mediumint' | 'int' | 'integer' => Some('Int32')
            case 'int8' | 'bigint' | 'bigserial' => Some('Int64')
            case 'tinyint' => Some('Int8')
            case 'float4' | 'float' => Some('Float32')
            case 'float8' | 'double' | 'double precision' => Some('Float64')
            case 'numeric' | 'money' | 'decimal' => Some('Decimal')
            case 'year' => Some('Int32')
            case 'date' | 'time' | 'timetz' | 'timestamp' | 'timestamptz' |
                'datetime' | 'timestamp with time zone' => Some('DateTime')
            case 'interval' => Some('Duration')
            case 'char' | 'bpchar' | 'varchar' | 'character varying' | 'text' | 'clob' | 'json' | 'jsonb' |
                'xml' | 'uuid' | 'nvarchar' | 'tinytext' | 'mediumtext' | 'longtext' | 'enum' | 'set' =>
                Some('String')
            case 'bytea' | 'binary' | 'varbinary' | 'blob' | 'bit' | 'varbit' | 'image' |
                'tinyblob' | 'mediumblob' | 'longblob' => Some('Array<Byte>')
            case 'tinyint unsigned' => Some('UInt8')
            case 'smallint unsigned' => Some('UInt16')
            case 'mediumint unsigned' | 'int unsigned' | 'integer unsigned' => Some('UInt32')
            case 'bigint unsigned' => Some('UInt64')
            case _ => None<String>
        }
    }

    /** 按列类型从物理结果集读一格并编码为 `Data`（fdbm 侧唯一取值入口）；SQL NULL → `DataNone`。 */
    public static func readData(result: QueryResult, index: Int64, typeName: String): Data {
        match (readType(typeName)) {
            case SqlReadType.Boolean => cellOf<Bool>(result, index)
            case SqlReadType.I8 => cellOf<Int8>(result, index)
            case SqlReadType.I16 => cellOf<Int16>(result, index)
            case SqlReadType.I32 => cellOf<Int32>(result, index)
            case SqlReadType.I64 => cellOf<Int64>(result, index)
            case SqlReadType.U8 => cellOf<UInt8>(result, index)
            case SqlReadType.U16 => cellOf<UInt16>(result, index)
            case SqlReadType.U32 => cellOf<UInt32>(result, index)
            case SqlReadType.U64 => cellOf<UInt64>(result, index)
            case SqlReadType.F32 => cellOf<Float32>(result, index)
            case SqlReadType.F64 => cellOf<Float64>(result, index)
            case SqlReadType.Decimal => cellOf<Decimal>(result, index)
            case SqlReadType.BigInt => cellOf<BigInt>(result, index)
            case SqlReadType.DateTime => cellOf<DateTime>(result, index)
            case SqlReadType.Duration => cellOf<Duration>(result, index)
            case SqlReadType.Text => cellOf<String>(result, index)
            case SqlReadType.Bytes => cellOf<Array<Byte>>(result, index)
            // `std.io.InputStream` 列：读到 EOF 后整块返回（不得截断成首块）
            case SqlReadType.Stream => readChunk(readStream(result, index), 0).toData()
            // 未识别拼写：按 `String` 读（`canonicalName` 的兜底口径），原始拼写入日志
            case SqlReadType.Unknown =>
                logger.warn('unknown column typeName \'${typeName}\', reading it as String')
                cellOf<String>(result, index)
        }
    }

    private static func cellOf<T>(result: QueryResult, index: Int64): Data where T <: DataFields<T> {
        match (result.getOrNull<T>(index)) {
            case Some(x) => x.toData()
            case _ => DataNone.INSTANCE
        }
    }

    /**
     * 打开该列的流并返回。
     *
     * **同一行同一列只调用一次**（对真流式驱动，重复 `get<InputStream>` 等于重复取列值），
     * 返回的流由 fdbm 的 `QueryCursor` 按行缓存持有；NULL 列返回 0 字节的空流。
     */
    public static func readStream(result: QueryResult, index: Int64): InputStream {
        match (result.getOrNull<InputStream>(index)) {
            case Some(s) => s
            // std.io 没有 ByteArrayInputStream：空字节流用空 `ByteBuffer`（读即返回 0，等价 EOF）
            case _ => ByteBuffer()
        }
    }

    /**
     * 从已打开的流里读一块：循环 `read` 直到凑满 `size` 或某次 `read` 返回 0；返回实际字节（可能为空）。
     *
     * `size <= 0` 表示**读至 EOF**（用于整块物化大对象）。单次临时缓冲不超过
     * `DEFAULT_STREAM_CHUNK`，总内存上界为「已读字节 + 一块缓冲」，不按剩余长度整块申请。
     *
     * EOF 的线上表征是**后续请求返回空数组**，调用方**不得**以"短块"判定流结束。
     */
    public static func readChunk(stream: InputStream, size: Int64): Array<Byte> {
        let toEnd = size <= 0
        let out = ArrayList<Byte>()
        var got = 0i64
        while (toEnd || got < size) {
            let remaining = if (toEnd) { DEFAULT_STREAM_CHUNK } else { size - got }
            let want = if (remaining < DEFAULT_STREAM_CHUNK) { remaining } else { DEFAULT_STREAM_CHUNK }
            let tmp = Array<Byte>(want, repeat: 0u8)
            let n = stream.read(tmp)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.add(tmp[i])
            }
            got += n
        }
        out.toArray()
    }

    /**
     * 便捷版（一次性场景）：等价于 `readChunk(readStream(result, index), size)`。
     * **游标路径不要用它** —— 每次调用都会重新打开流。
     */
    public static func readStream(result: QueryResult, index: Int64, size: Int64): Array<Byte> {
        readChunk(readStream(result, index), size)
    }

    /**
     * 参数编码（`Statement.set<T>`）：运行时按受支持类型判定（`std` 的 `T` 无编译期约束）。
     *
     * 命中即构造对应 `Data`；否则 `ToData` 兜底；都不满足抛 `DataException`（由 `DbdStatement` 统一包成
     * `DbdException(CONVERSION)`）。`InputStream` 参数需一次性物化成整块字节（列为限制）。
     */
    public static func encodeParameter<T>(value: T): Data {
        let any: Any = value
        match (any) {
            case x: Bool => x.toData()
            case x: Int8 => x.toData()
            case x: Int16 => x.toData()
            case x: Int32 => x.toData()
            case x: Int64 => x.toData()
            case x: IntNative => x.toData()
            case x: UInt8 => x.toData()
            case x: UInt16 => x.toData()
            case x: UInt32 => x.toData()
            case x: UInt64 => x.toData()
            case x: UIntNative => x.toData()
            case x: Float32 => x.toData()
            case x: Float64 => x.toData()
            case x: Decimal => x.toData()
            case x: BigInt => x.toData()
            case x: String => x.toData()
            case x: DateTime => x.toData()
            case x: Duration => x.toData()
            case x: Array<Byte> => x.toData()
            case x: InputStream =>
                // 读至 EOF；内存上界 = 已读字节 + 一块缓冲（D01）
                try {
                    readChunk(x, 0).toData()
                } catch (e: DataException) {
                    throw e
                } catch (e: Exception) {
                    throw DataException('failed to read InputStream parameter: ${e.message}', e)
                }
            case x: ToData => x.toData()
            case _ => throw DataException('unsupported parameter type ${TypeInfo.of<T>()}')
        }
    }

    /**
     * 单元格（标量）解码，**B 口径（越界即报错）**：
     *
     * - `DataNone`（SQL NULL）→ `None<T>`；
     * - 数值越界 / 带小数部分 → 抛 `DataException` 或 `OverflowException`（两种都要由调用方捕获）；
     * - 不可转换 → `DataException`；
     * - 宽松转换仍保留（`IGNORE_FIELD_TYPE_NOT_MATCH` 在位，如任意列 `get<String>` → `x.toString()`）。
     */
    public static func decode<T>(data: Data): ?T where T <: DataFields<T> {
        if (data is DataNone) {
            return None<T>
        }
        // 分数值读整数类型：B 口径要求报错，**不得截断**。
        // `convert` 走 `Decimal.toIntX` 会把 3.7 截成 3（不视为溢出），故在此显式拦截。
        // 只在"带小数部分"这一条冷路径上做类型判定，不影响热路径。
        if (let r: DataReal <- data) {
            if (!r.integer && isIntegerTarget<T>()) {
                throw DataException(
                    'column value ${r.data} has a fractional part, cannot be read as ${TypeInfo.of<T>()}')
            }
        }
        convert<T>(data, flag: CELL_READ_FLAG)
    }

    /** `T` 是否为整数类型（含 `IntNative` / `UIntNative`）；仅供"分数值读整数"这条冷路径使用。 */
    private static func isIntegerTarget<T>(): Bool where T <: DataFields<T> {
        let ti = TypeInfo.of<T>()
        ti.isSubtypeOf(TI_INT8) || ti.isSubtypeOf(TI_INT16) || ti.isSubtypeOf(TI_INT32) ||
            ti.isSubtypeOf(TI_INT64) || ti.isSubtypeOf(TI_INT_NATIVE) || ti.isSubtypeOf(TI_UINT8) ||
            ti.isSubtypeOf(TI_UINT16) || ti.isSubtypeOf(TI_UINT32) || ti.isSubtypeOf(TI_UINT64) ||
            ti.isSubtypeOf(TI_UINT_NATIVE)
    }

    private static let TI_INT8 = TypeInfo.of<Int8>()
    private static let TI_INT16 = TypeInfo.of<Int16>()
    private static let TI_INT32 = TypeInfo.of<Int32>()
    private static let TI_INT64 = TypeInfo.of<Int64>()
    private static let TI_INT_NATIVE = TypeInfo.of<IntNative>()
    private static let TI_UINT8 = TypeInfo.of<UInt8>()
    private static let TI_UINT16 = TypeInfo.of<UInt16>()
    private static let TI_UINT32 = TypeInfo.of<UInt32>()
    private static let TI_UINT64 = TypeInfo.of<UInt64>()
    private static let TI_UINT_NATIVE = TypeInfo.of<UIntNative>()
}
