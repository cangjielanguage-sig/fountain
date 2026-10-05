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
package fountain::f_orm.wrap

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mockdb.*

/** 取值路径只做类型判定、不读流内容：read 返回构造时的 tag，用例借它断言取回的正是本实例 */
private class ProbeInputStream <: InputStream {
    private let tag: Int64
    ProbeInputStream(tag: Int64) {
        this.tag = tag
    }
    public func read(buffer: Array<Byte>): Int64 {
        tag
    }
}

/**
 * QueryResultWrap 取值路径的契约（bug.md §1.13 / ORM-2）。
 *
 * 修复把「列类型 -> 取值」的判定从「逐单元格内联 match」改成「按列构造取值器」，
 * 本用例钉住语义不变：按索引/按列名取值同源、各 typeName 分支与别名、
 * indexStartsWith 偏移（驱动物理列从 1 开始）、未知类型走 String 兜底、
 * String 到目标数值类型的转换，以及 list 缓存按行重置。
 */
@Test
public class QueryResultWrapTest {
    /** 夹具：一行 values + 列声明（列名, typeName），返回构造好的包装 */
    private func fixture(values: Array<Any>, columns: Array<(String, String)>): QueryResultWrap {
        MOCKDB.clearQueryResult()
        MOCKDB.addQueryResultRow(values)
        for ((name, typeName) in columns) {
            MOCKDB.addQueryResultColumnInfo(name: name, nullable: false, typeName: typeName)
        }
        QueryResultWrap('mockdb', MockQueryResult())
    }

    /** 按索引与按列名是同一条取值路径；未知列名与越界索引都返回 None（不是抛错） */
    @TestCase
    public func testReadByIndexAndByColumnName(): Unit {
        let w = fixture([Int64(7), 'bob', 95.5, true], [
            ('id', 'SqlBigInt'), ('name', 'SqlVarchar'), ('score', 'SqlDouble'), ('active', 'SqlBool')
        ])
        @Assert(true, w.next())
        // 按索引
        @Assert(Some(7), w.getOrNull<Int64>(0))
        @Assert(Some('bob'), w.getOrNull<String>(1))
        @Assert(Some(95.5), w.getOrNull<Float64>(2))
        @Assert(Some(true), w.getOrNull<Bool>(3))
        // 按列名
        @Assert(Some(7), w.getOrNull<Int64>('id'))
        @Assert('bob', w.get<String>('name'))
        @Assert(Some(95.5), w.getOrNull<Float64>('score'))
        @Assert(Some(true), w.getOrNull<Bool>('active'))
        // 未知列名 / 越界索引
        @Assert(None, w.getOrNull<Int64>('no_such_column'))
        @Assert(None, w.getOrNull<Int64>(99))
        // 列信息来自构造期快照，顺序与声明一致
        @Assert(4, w.columnInfos.size)
        @Assert('id', w.columnInfos[0].name)
        @Assert('active', w.columnInfos[3].name)
    }

    /** 每个取值器分支（含别名与未知类型的 String 兜底）都必须取到原值 */
    @TestCase
    public func testEveryReaderBranchAndAlias(): Unit {
        let clob = ProbeInputStream(7)
        let blob = ProbeInputStream(8)
        let bin12: Array<Byte> = [UInt8(1), UInt8(2)]
        let bin3: Array<Byte> = [UInt8(3)]
        let decimal = Decimal.parse('12.34')
        let moment = DateTime.now()
        let span = Duration.second * 3
        let w = fixture(
            ['char-v', 'text-v', clob, blob, bin12, bin3, decimal, decimal, true,
             Int8(1), UInt8(2), Int16(3), UInt16(4), Int32(5), UInt32(6), Int64(7), UInt64(8),
             Float32(1.5), Float64(2.5), moment, moment, span, 'fallback-v'],
            [('c0', 'SqlChar'), ('c1', 'text'), ('c2', 'SqlBlob'), ('c3', 'std.io.InputStream'),
             ('c4', 'SqlVarBinary'), ('c5', 'bytea'), ('c6', 'SqlDecimal'), ('c7', 'money'),
             ('c8', 'SqlBool'), ('c9', 'Int8'), ('c10', 'Byte'), ('c11', 'SqlSmallInt'),
             ('c12', 'UInt16'), ('c13', 'SqlInteger'), ('c14', 'int4'), ('c15', 'SqlBigInt'),
             ('c16', 'UInt64'), ('c17', 'SqlReal'), ('c18', 'float8'), ('c19', 'SqlTimestamp'),
             ('c20', ''), ('c21', 'SqlInterval'), ('c22', 'weird_unknown_type')])
        @Assert(true, w.next())
        @Assert(Some('char-v'), w.getOrNull<String>(0))
        @Assert(Some('text-v'), w.getOrNull<String>(1))
        match (w.getOrNull<InputStream>(2)) {
            case Some(x) => @Assert(7, x.read(Array<Byte>(1, repeat: 0)))
            case _ => @Assert(false)
        }
        match (w.getOrNull<InputStream>(3)) {
            case Some(x) => @Assert(8, x.read(Array<Byte>(1, repeat: 0)))
            case _ => @Assert(false)
        }
        @Assert(Some(bin12), w.getOrNull<Array<Byte>>(4))
        @Assert(Some(bin3), w.getOrNull<Array<Byte>>(5))
        @Assert(Some(decimal), w.getOrNull<Decimal>(6))
        @Assert(Some(decimal), w.getOrNull<Decimal>(7))
        @Assert(Some(true), w.getOrNull<Bool>(8))
        @Assert(Some(Int8(1)), w.getOrNull<Int8>(9))
        @Assert(Some(UInt8(2)), w.getOrNull<UInt8>(10))
        @Assert(Some(Int16(3)), w.getOrNull<Int16>(11))
        @Assert(Some(UInt16(4)), w.getOrNull<UInt16>(12))
        @Assert(Some(Int32(5)), w.getOrNull<Int32>(13))
        @Assert(Some(UInt32(6)), w.getOrNull<UInt32>(14))
        @Assert(Some(Int64(7)), w.getOrNull<Int64>(15))
        @Assert(Some(UInt64(8)), w.getOrNull<UInt64>(16))
        @Assert(Some(Float32(1.5)), w.getOrNull<Float32>(17))
        @Assert(Some(Float64(2.5)), w.getOrNull<Float64>(18))
        @Assert(Some(moment), w.getOrNull<DateTime>(19))
        // typeName 为空串时按 DateTime 处理（既有口径）
        @Assert(Some(moment), w.getOrNull<DateTime>(20))
        @Assert(Some(span), w.getOrNull<Duration>(21))
        // 未知 typeName 落最后一个分支：按 String 取值
        @Assert(Some('fallback-v'), w.getOrNull<String>(22))
    }

    /** indexStartsWith 非 0 的驱动：逻辑列 i 读物理列 i + offset（默认分支见上一个用例） */
    @TestCase
    public func testIndexStartsWithNonZeroDriverOffsetsPhysicalIndex(): Unit {
        let probeDriver = 'ormIndexStartsWithProbe'
        let key = ORMConfig.genKey(probeDriver, ORMConfig.indexStartsWithZero)
        Config.set([(key, 'false')])
        try {
            @Expect(1, ORMConfig.getIndexStartsWith(driverName: probeDriver))
            MOCKDB.clearQueryResult()
            // 物理第 0 列留给驱动自身，逻辑第 0 列从物理第 1 列开始
            MOCKDB.addQueryResultRow(['reserved', 'col0', Int64(42)])
            MOCKDB.addQueryResultColumnInfo(name: 'c0', nullable: false, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultColumnInfo(name: 'c1', nullable: false, typeName: 'SqlBigInt')
            let w = QueryResultWrap(probeDriver, MockQueryResult())
            @Assert(true, w.next())
            @Assert(Some('col0'), w.getOrNull<String>(0))
            @Assert(Some(Int64(42)), w.getOrNull<Int64>(1))
            @Assert(Some('col0'), w.getOrNull<String>('c0'))
            @Assert(Some(Int64(42)), w.getOrNull<Int64>('c1'))
            // 越界判定仍按逻辑列数
            @Assert(None, w.getOrNull<String>(2))
        } finally {
            Config.set([(key, 'true')])
        }
    }

    /** 驱动给 String、调用方要求数值类型时走转换兜底；无法解析按既有口径抛 ORMException */
    @TestCase
    public func testStringColumnConvertsToRequestedNumericType(): Unit {
        let ok = fixture(['42'], [('c0', 'SqlVarchar')])
        @Assert(true, ok.next())
        @Assert(Some(Int64(42)), ok.getOrNull<Int64>(0))

        let bad = fixture(['not-a-number'], [('c0', 'SqlVarchar')])
        @Assert(true, bad.next())
        var caught = false
        try {
            bad.getOrNull<Int64>(0)
        } catch (_: ORMException) {
            caught = true
        }
        @Assert(true, caught)
    }

    /** 每行读到的必须是本行的值：next() 必须清掉上一行的取值缓存 */
    @TestCase
    public func testListCacheIsResetBetweenRows(): Unit {
        MOCKDB.clearQueryResult()
        MOCKDB.addQueryResultRow([Int64(1)])
        MOCKDB.addQueryResultRow([Int64(2)])
        MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlBigInt')
        let w = QueryResultWrap('mockdb', MockQueryResult())
        @Assert(true, w.next())
        @Assert(Some(1), w.getOrNull<Int64>(0))
        @Assert(true, w.next())
        @Assert(Some(2), w.getOrNull<Int64>(0))
        @Assert(false, w.next())
    }
}
