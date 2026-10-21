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

import std.io.{ByteBuffer, IOException, InputStream}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*
import fountain::f_mockdb.*

/** 桩流每次只吐 1 字节 → 必须循环多次凑满 size（证明 `readChunk` 不是"一次 read"）。 */
private class DribbleStream <: InputStream {
    private var left: Int64
    DribbleStream(left: Int64) {
        this.left = left
    }
    public func read(buffer: Array<Byte>): Int64 {
        if (left <= 0) {
            return 0
        }
        buffer[0] = 0x41u8
        left--
        1
    }
}

/** 记录每次 `read` 的缓冲长度与调用次数：验证分块物化的内存上界（D01）。 */
private class RecordingStream <: InputStream {
    private var left: Int64
    public var maxBuffer: Int64 = 0
    public var calls: Int64 = 0
    RecordingStream(left: Int64) {
        this.left = left
    }
    public func read(buffer: Array<Byte>): Int64 {
        calls += 1
        if (buffer.size > maxBuffer) {
            maxBuffer = buffer.size
        }
        if (left <= 0) {
            return 0
        }
        let n = if (buffer.size < left) { buffer.size } else { left }
        for (i in 0..n) {
            buffer[i] = 0x41u8
        }
        left -= n
        n
    }
}

/** 每次 `read` 都失败的流（D01：异常必须包成 `DataException`）。 */
private class FailingStream <: InputStream {
    public func read(buffer: Array<Byte>): Int64 {
        throw IOException('boom')
    }
}

/** Step 1.8 `SqlTypes` 与 `SqlReadType`（设计 §3.9；识别/归一表见 fdbm §9.6） */
@Test
public class SqlTypesTest {

    // ========== readType / canonicalName：三类写法识别 ==========

    @TestCase
    public func readTypeRecognizesSqlAbstractNames(): Unit {
        @Assert(SqlTypes.readType('SqlVarchar'), SqlReadType.Text)
        @Assert(SqlTypes.readType('SqlBlob'), SqlReadType.Bytes)
        @Assert(SqlTypes.readType('SqlBigInt'), SqlReadType.I64)
        @Assert(SqlTypes.readType('SqlNullableBigInt'), SqlReadType.I64)
        @Assert(SqlTypes.readType('SqlBool'), SqlReadType.Boolean)
        @Assert(SqlTypes.readType('SqlTimestamp'), SqlReadType.DateTime)
    }

    @TestCase
    public func readTypeRecognizesCangjieNames(): Unit {
        @Assert(SqlTypes.readType('Int64'), SqlReadType.I64)
        @Assert(SqlTypes.readType('String'), SqlReadType.Text)
        @Assert(SqlTypes.readType('Array<Byte>'), SqlReadType.Bytes)
        @Assert(SqlTypes.readType('std.io.InputStream'), SqlReadType.Stream)
        @Assert(SqlTypes.readType('std.time.DateTime'), SqlReadType.DateTime)
        @Assert(SqlTypes.readType('Duration'), SqlReadType.Duration)
    }

    @TestCase
    public func readTypeRecognizesDialectSpellings(): Unit {
        @Assert(SqlTypes.readType('int4'), SqlReadType.I32)
        @Assert(SqlTypes.readType('bytea'), SqlReadType.Bytes)
        @Assert(SqlTypes.readType('timestamptz'), SqlReadType.DateTime)
        @Assert(SqlTypes.readType('money'), SqlReadType.Decimal)
        @Assert(SqlTypes.readType('BIGINT'), SqlReadType.I64)
        @Assert(SqlTypes.readType('TINYINT(1)'), SqlReadType.Boolean)
        @Assert(SqlTypes.readType('TINYINT UNSIGNED'), SqlReadType.U8)
        @Assert(SqlTypes.readType('timestamp with time zone'), SqlReadType.DateTime)
        @Assert(SqlTypes.readType('varchar(64)'), SqlReadType.Text)
        @Assert(SqlTypes.readType('decimal(10,2)'), SqlReadType.Decimal)
    }

    @TestCase
    public func readTypeUnknownForUnlistedSpellings(): Unit {
        // 未知兜底族：几何 / 网络 / 全文检索（fdbm §9.6 明列为 WARN 兜底）
        @Assert(SqlTypes.readType('GEOMETRY'), SqlReadType.Unknown)
        @Assert(SqlTypes.readType('inet'), SqlReadType.Unknown)
        @Assert(SqlTypes.readType('tsvector'), SqlReadType.Unknown)
    }

    /** `uuid` / `jsonb` 在 fdbm §9.6 的归一表里是**已知**文本类型（不是未知兜底）。 */
    @TestCase
    public func readTypeKnownTextSpellings(): Unit {
        @Assert(SqlTypes.readType('uuid'), SqlReadType.Text)
        @Assert(SqlTypes.readType('jsonb'), SqlReadType.Text)
    }

    @TestCase
    public func canonicalNameNormalizes(): Unit {
        @Assert(SqlTypes.canonicalName('SqlVarchar'), 'String')
        @Assert(SqlTypes.canonicalName('int4'), 'Int32')
        @Assert(SqlTypes.canonicalName('BIGINT'), 'Int64')
        @Assert(SqlTypes.canonicalName('bytea'), 'Array<Byte>')
        @Assert(SqlTypes.canonicalName('TINYINT(1)'), 'Bool')
        @Assert(SqlTypes.canonicalName('timestamp with time zone'), 'DateTime')
        @Assert(SqlTypes.canonicalName('uuid'), 'String')
        @Assert(SqlTypes.canonicalName('GEOMETRY'), 'String')
    }

    /** 仓颉类型名**原样通过**；`InputStream` 只由驱动自报产生。 */
    @TestCase
    public func canonicalNamePassesCangjieNamesThrough(): Unit {
        @Assert(SqlTypes.canonicalName('Int64'), 'Int64')
        @Assert(SqlTypes.canonicalName('std.io.InputStream'), 'std.io.InputStream')
    }

    /** 关键回归：方言大对象名（`bytea` / `*BLOB`）不得归一成流。 */
    @TestCase
    public func dialectLargeObjectsNeverBecomeStreams(): Unit {
        @Assert(SqlTypes.canonicalName('bytea'), 'Array<Byte>')
        @Assert(SqlTypes.canonicalName('BLOB'), 'Array<Byte>')
        @Assert(SqlTypes.canonicalName('LONGBLOB'), 'Array<Byte>')
        @Assert(SqlTypes.canonicalName('SqlBlob'), 'Array<Byte>')
    }

    @TestCase
    public func sqlReadTypeToString(): Unit {
        @Assert(SqlReadType.I64.toString(), 'Int64')
        @Assert(SqlReadType.Text.toString(), 'String')
        @Assert(SqlReadType.Stream.toString(), 'Stream')
        @Assert(SqlReadType.Unknown.toString(), 'Unknown')
    }

    // ========== encodeParameter<T> ==========

    @TestCase
    public func encodeParameterSupportedTypes(): Unit {
        @Assert(SqlTypes.encodeParameter<Bool>(true).toString(), DataAny(DataBool.TRUE).data.toString())
        @Assert(SqlTypes.encodeParameter<Int64>(1).toString(), DataAny(DataReal(1)).data.toString())
        @Assert(SqlTypes.encodeParameter<String>('a').toString(), DataAny(DataString('a')).data.toString())
    }

    /**
     * D01：`InputStream` 参数必须按块读到 EOF 再编码 —— 1 MiB 流既不能按剩余长度整块申请，
     * 也不能只读首块。当前实现按 `Int64.Max` 申请，会抛分配失败。
     */
    @TestCase
    public func encodeParameterStreamReadsToEnd(): Unit {
        let size = 1024 * 1024
        let src = Array<Byte>(size, repeat: 0u8)
        for (i in 0..size) {
            src[i] = UInt8(i % 251)
        }
        let data = SqlTypes.encodeParameter<InputStream>(ByteBuffer(src))
        let back = SqlTypes.decode<Array<Byte>>(data).getOrThrow()
        @Assert(back.size, size)
        @Assert(back[0], src[0])
        @Assert(back[size / 2], src[size / 2])
        @Assert(back[size - 1], src[size - 1])
    }

    /** D01：读取期异常包成 `DataException`（不把裸 `IOException` 抛给调用方）。 */
    @TestCase
    public func encodeParameterStreamFailureIsDataException(): Unit {
        var threw = false
        try {
            SqlTypes.encodeParameter<InputStream>(FailingStream())
        } catch (_: DataException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func encodeParameterUnsupportedTypeThrows(): Unit {
        var threw = false
        try {
            SqlTypes.encodeParameter(SqlPayload('x'))
        } catch (_: DataException) {
            threw = true
        }
        @Assert(!threw)
    }

    // ========== decode<T>：B 口径（越界即报错） ==========

    @TestCase
    public func decodeNullYieldsNone(): Unit {
        @Assert(SqlTypes.decode<Int64>(DataNone.INSTANCE).isNone())
    }

    @TestCase
    public func decodeInRangeIsExact(): Unit {
        @Assert(SqlTypes.decode<Int64>(DataReal(1)).getOrThrow(), 1)
        @Assert(SqlTypes.decode<Int32>(DataReal(1)).getOrThrow(), 1)
    }

    /** 越界：抛异常，且**不回绕**（`DataReal(300)` → Int8 不得得到 44）。 */
    @TestCase
    public func decodeOutOfRangeThrows(): Unit {
        var threw = false
        try {
            SqlTypes.decode<Int8>(DataReal(300))
        } catch (_: DataException) {
            threw = true
        } catch (_: OverflowException) {
            threw = true
        }
        @Assert(threw)
    }

    /** 分数值：抛异常，不截断。 */
    @TestCase
    public func decodeFractionalThrows(): Unit {
        var threw = false
        try {
            SqlTypes.decode<Int64>(DataReal(3.7))
        } catch (_: DataException) {
            threw = true
        } catch (_: OverflowException) {
            threw = true
        }
        @Assert(threw)
    }

    /** 宽松转换保留：任意列 `get<String>` 走 `toString()`。 */
    @TestCase
    public func decodeToStringIsLenient(): Unit {
        @Assert(SqlTypes.decode<String>(DataReal(1)).getOrThrow(), '1')
    }

    /** 不可转换：非数字字符串读成整数 → 抛 `DataException`。 */
    @TestCase
    public func decodeNotConvertibleThrows(): Unit {
        var threw = false
        try {
            SqlTypes.decode<Int64>(DataString('abc'))
        } catch (_: DataException) {
            threw = true
        }
        @Assert(threw)
    }

    // ========== readChunk：循环读满 / 短块非 EOF ==========

    @TestCase
    public func readChunkLoopsUntilFull(): Unit {
        let chunk = SqlTypes.readChunk(DribbleStream(4), 4)
        @Assert(chunk.size, 4)
        @Assert(chunk[0], 0x41u8)
    }

    @TestCase
    public func readChunkShortThenEof(): Unit {
        @Assert(SqlTypes.readChunk(DribbleStream(2), 10).size, 2)
        @Assert(SqlTypes.readChunk(DribbleStream(0), 10).size, 0)
    }

    /** D01：`size <= 0` 表示「读至 EOF」，且单次 `read` 的缓冲不超过一块（64 KiB）。 */
    @TestCase
    public func readChunkToEndUsesBoundedBuffers(): Unit {
        let total = 200 * 1024
        let stream = RecordingStream(total)
        let out = SqlTypes.readChunk(stream, 0)
        @Assert(out.size, total)
        @Assert(stream.maxBuffer <= DEFAULT_STREAM_CHUNK, true)
        @Assert(stream.calls >= 4, true)
        @Assert(out[0], 0x41u8)
        @Assert(out[total - 1], 0x41u8)
    }

    /** D01：显式 size 仍只读满该长度，且仍然分块。 */
    @TestCase
    public func readChunkExplicitSizeIsBounded(): Unit {
        let stream = RecordingStream(200 * 1024)
        let out = SqlTypes.readChunk(stream, 70 * 1024)
        @Assert(out.size, 70 * 1024)
        @Assert(stream.maxBuffer <= DEFAULT_STREAM_CHUNK, true)
        @Assert(stream.calls >= 2, true)
    }

    // ========== readData / readStream：真实（mock）结果集 ==========

    /** f_mockdb 的 NULL 语义：单元格值必须是 `Option<Any>` 的 None（`Option<String>` 匹配不上）。 */
    private func nullRow(): Array<Any> {
        let nullCell: Option<Any> = None
        [nullCell]
    }

    private func mockResult(typeName: String, row: Array<Any>): QueryResult {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'c0', nullable: true, typeName: typeName)
            MOCKDB.addQueryResultRow(row)
        }
        MOCKDB.toThrowOnExecuting = false
        let stmt = MockConnection().prepareStatement('select c0 from t')
        let rs = stmt.query()
        rs.next()
        rs
    }

    @TestCase
    public func readDataEncodesCells(): Unit {
        @Assert(SqlTypes.readData(mockResult('Int64', [7]), 0, 'Int64').toString(),
            DataAny(DataReal(7)).data.toString())
        @Assert(SqlTypes.readData(mockResult('String', ['x']), 0, 'String').toString(),
            DataAny(DataString('x')).data.toString())
        @Assert(SqlTypes.readData(mockResult('String', nullRow()), 0, 'String') is DataNone)
    }

    /** D02：流列必须读到 EOF 整块返回（200 KiB 不得截断成首块 64 KiB）。 */
    @TestCase
    public func readDataReadsStreamColumnToEnd(): Unit {
        let size = 200 * 1024
        let src = Array<Byte>(size, repeat: 0x42u8)
        let data = SqlTypes.readData(mockResult('std.io.InputStream', [ByteBuffer(src)]), 0,
            'std.io.InputStream')
        let back = SqlTypes.decode<Array<Byte>>(data).getOrThrow()
        @Assert(back.size, size)
        @Assert(back[size - 1], 0x42u8)
    }

    /** D02：`Unknown` 按 `String` 读（不得走流分支），且失败可被调用方识别。 */
    @TestCase
    public func readDataUnknownTypeFallsBackToString(): Unit {
        let data = SqlTypes.readData(mockResult('weird_type', ['x']), 0, 'weird_type')
        @Assert(data.toString(), DataAny(DataString('x')).data.toString())
    }

    /** NULL 列 → 0 字节空流（立即读到 0）。 */
    @TestCase
    public func readStreamOnNullYieldsEmptyStream(): Unit {
        let s = SqlTypes.readStream(mockResult('std.io.InputStream', nullRow()), 0)
        @Assert(s.read(Array<Byte>(8, repeat: 0u8)), 0)
    }

    /** 非流列 → 驱动抛 `SqlException` 时**原样透传**（不吞、不转成别的异常）。 */
    @TestCase
    public func readStreamOnNonStreamColumnPropagates(): Unit {
        var threw = false
        try {
            SqlTypes.readStream(mockResult('Int64', [7]), 0)
        } catch (_: SqlException) {
            threw = true
        }
        @Assert(threw)
    }

    /** 便捷版 = `readChunk(readStream(result, index), size)`；非流列由驱动抛 `SqlException` 并原样透传。 */
    @TestCase
    public func readStreamConveniencePropagatesOnNonStreamColumn(): Unit {
        var threw = false
        try {
            SqlTypes.readStream(mockResult('String', ['ab']), 0, 2)
        } catch (_: SqlException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func byteBufferIsUsableAsEmptyStream(): Unit {
        @Assert(ByteBuffer().read(Array<Byte>(4, repeat: 0u8)), 0)
    }
}
