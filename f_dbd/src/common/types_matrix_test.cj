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
import std.io.ByteBuffer
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*
import fountain::f_mockdb.*

/**
 * T03 类型矩阵（设计 §8）：三层都要覆盖全表，任何一层漏一种类型都在这里失败。
 *
 * 1. `SqlTypes.encodeParameter`：全部标量 + 字节 + 集合（`ToData` 兜底）；
 * 2. `SqlTypes.readData`：`SqlReadType` 的每个分支（含 `Stream` / `Unknown`）；
 * 3. `QueryResultImpl.get<T>`：16 个具体类型 + `Rune`。
 */
@Test
public class SqlTypesMatrixTest {

    // ==================== 1. encodeParameter ====================

    /** 标量全表：编码后按同一类型解码必须回到原值（不丢精度、不换类型）。 */
    @TestCase
    public func encodeParameterCoversScalarMatrix(): Unit {
        @Assert(roundTrips(true), true)
        @Assert(roundTrips(-8i8), true)
        @Assert(roundTrips(-1600i16), true)
        @Assert(roundTrips(-32000i32), true)
        @Assert(roundTrips(-64000i64), true)
        @Assert(roundTrips(8u8), true)
        @Assert(roundTrips(1600u16), true)
        @Assert(roundTrips(32000u32), true)
        @Assert(roundTrips(64000u64), true)
        @Assert(roundTrips(IntNative(-64)), true)
        @Assert(roundTrips(UIntNative(64)), true)
        @Assert(roundTrips(1.5f32), true)
        @Assert(roundTrips(2.5f64), true)
        @Assert(roundTrips(Decimal.parse('123.45')), true)
        @Assert(roundTrips(BigInt.parse('123456789012345678901')), true)
        @Assert(roundTrips('文本'), true)
        @Assert(roundTrips(DateTime.now()), true)
        @Assert(roundTrips(Duration.second * 5), true)
    }

    /** 字节与集合：`Array<Byte>` 走专用分支，其余集合走 `ToData`（`DataCollection`）。 */
    @TestCase
    public func encodeParameterCoversBytesAndCollections(): Unit {
        let bytes = [1u8, 2u8, 3u8]
        @Assert(roundTrips(bytes), true)

        let array = [1i64, 2i64, 3i64]
        let arrayBack = SqlTypes.decode<Array<Int64>>(SqlTypes.encodeParameter(array))
        @Assert(arrayBack.isSome(), true)
        @Assert(arrayBack.getOrThrow().size, 3)

        let list = ArrayList<String>(['a', 'b'])
        let listBack = SqlTypes.decode<ArrayList<String>>(SqlTypes.encodeParameter(list))
        @Assert(listBack.isSome(), true)
        @Assert(listBack.getOrThrow().size, 2)

        let set = HashSet<String>()
        set.add('x')
        let setBack = SqlTypes.decode<HashSet<String>>(SqlTypes.encodeParameter(set))
        @Assert(setBack.isSome(), true)
        @Assert(setBack.getOrThrow().contains('x'), true)
    }

    // ==================== 2. readData ====================

    /** `SqlReadType` 的每个非流分支：读出的 `Data` 与该单元格等价。 */
    @TestCase
    public func readDataCoversEverySqlReadType(): Unit {
        let stamp = DateTime.now()
        let span = Duration.second * 5
        let cases: Array<(String, Any, Data)> = [
            ('Bool', true, true.toData()),
            ('Int8', -8i8, (-8i8).toData()),
            ('Int16', -1600i16, (-1600i16).toData()),
            ('Int32', -32000i32, (-32000i32).toData()),
            ('Int64', -64000i64, (-64000i64).toData()),
            ('UInt8', 8u8, 8u8.toData()),
            ('UInt16', 1600u16, 1600u16.toData()),
            ('UInt32', 32000u32, 32000u32.toData()),
            ('UInt64', 64000u64, 64000u64.toData()),
            ('Float32', 1.5f32, 1.5f32.toData()),
            ('Float64', 2.5f64, 2.5f64.toData()),
            ('Decimal', Decimal.parse('123.45'), Decimal.parse('123.45').toData()),
            ('BigInt', BigInt.parse('123456789012345678901'),
                BigInt.parse('123456789012345678901').toData()),
            ('DateTime', stamp, stamp.toData()),
            ('Duration', span, span.toData()),
            ('String', '文本', DataString('文本')),
            ('Array<Byte>', [1u8, 2u8], [1u8, 2u8].toData())
        ]
        for ((typeName, value, expected) in cases) {
            let actual = SqlTypes.readData(matrixResult(typeName, [value]), 0, typeName)
            @Assert(actual.toString(), expected.toString())
        }
        // 方言拼写同样命中同一个分支（归一发生在 readType 内）
        let dialect = SqlTypes.readData(matrixResult('int4', [7i32]), 0, 'int4')
        @Assert(dialect.toString(), 7i32.toData().toString())
    }

    /** `Stream` 分支：读至 EOF（不是首块）；`Unknown` 分支：按 `String` 读。 */
    @TestCase
    public func readDataStreamAndUnknownBranches(): Unit {
        let payload = Array<Byte>(70 * 1024, repeat: 0x5Au8)
        let streamed = SqlTypes.readData(matrixResult('std.io.InputStream', [ByteBuffer(payload)]), 0,
            'std.io.InputStream')
        let back = SqlTypes.decode<Array<Byte>>(streamed).getOrThrow()
        @Assert(back.size, payload.size)

        let unknown = SqlTypes.readData(matrixResult('weird_type', ['x']), 0, 'weird_type')
        @Assert(unknown.toString(), DataString('x').toString())
    }

    // ==================== 3. QueryResultImpl.get<T> ====================

    /** 16 个具体类型 + `Rune`：每个分支都能落地为对应的仓颉值。 */
    @TestCase
    public func queryResultGetCoversConcreteTypeMatrix(): Unit {
        @Assert(getOf<Bool>(true.toData()), true)
        @Assert(getOf<Int8>((-8i8).toData()), (-8i8))
        @Assert(getOf<Int16>((-1600i16).toData()), (-1600i16))
        @Assert(getOf<Int32>((-32000i32).toData()), (-32000i32))
        @Assert(getOf<Int64>((-64000i64).toData()), (-64000i64))
        @Assert(getOf<UInt8>(8u8.toData()), 8u8)
        @Assert(getOf<UInt16>(1600u16.toData()), 1600u16)
        @Assert(getOf<UInt32>(32000u32.toData()), 32000u32)
        @Assert(getOf<UInt64>(64000u64.toData()), 64000u64)
        @Assert(getOf<Float32>(1.5f32.toData()), 1.5f32)
        @Assert(getOf<Float64>(2.5f64.toData()), 2.5f64)
        @Assert(getOf<String>(DataString('文本')), '文本')
        @Assert(getOf<Decimal>(Decimal.parse('123.45').toData()).toString(), '123.45')
        @Assert(getOf<BigInt>(BigInt.parse('123456789012345678901').toData()).toString(),
            '123456789012345678901')
        let bytes = getOf<Array<Byte>>([1u8, 2u8].toData())
        @Assert(bytes.size, 2)
        @Assert(bytes[1], 2u8)
        let stamp = DateTime.now()
        @Assert(getOf<DateTime>(stamp.toData()).toString(), stamp.toString())
        @Assert(getOf<Duration>((Duration.second * 5).toData()), Duration.second * 5)
        // Rune 列按 String 传输，单个 Rune 时还原
        @Assert(getOf<Rune>(DataString('A')), r'A')
    }

    /** 逐类型取值：每个 `T` 各用一个只含一列的结果集，避免单元格串行消耗。 */
    private func getOf<T>(cell: Data): T {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(cell)
        let result = QueryResultImplTestResult(stub, 'T')
        @Assert(result.impl.next(), true)
        let value = result.impl.get<T>(0)
        result.impl.close()
        value
    }
}

/** `StubSender` + `QueryResultImpl` 的小包装（`QueryResultImpl` 本身只暴露接口方法）。 */
class QueryResultImplTestResult {
    let impl: QueryResultImpl

    init(stub: StubSender, typeName: String) {
        let infos = ArrayList<ColumnInfoImpl>()
        infos.add(ColumnInfoImpl('c0', typeName, 20, 0, false, 21))
        this.impl = QueryResultImpl(QueryResultServerPayload(infos.toArray()), 'matrix', stub.send,
            closer: stub.close)
    }
}

/** 用一个 `Data` 往返编解码，判断是否回到同一文本表示。 */
func roundTrips<T>(value: T): Bool where T <: DataFields<T> {
    match (SqlTypes.decode<T>(SqlTypes.encodeParameter(value))) {
        case Some(back) => back.toData().toString() == value.toData().toString()
        case None => false
    }
}

/** f_mockdb 结果集：单行单列，单元格由调用方给定。 */
func matrixResult(typeName: String, row: Array<Any>): QueryResult {
    MOCKDB.clear()
    MOCKDB.execution = {_: String, _: ArrayList<Any> =>
        MOCKDB.addQueryResultColumnInfo(name: 'c0', nullable: true, typeName: typeName)
        MOCKDB.addQueryResultRow(row)
    }
    MOCKDB.toThrowOnExecuting = false
    let statement = MockConnection().prepareStatement('select c0 from t')
    let result = statement.query()
    result.next()
    result
}
