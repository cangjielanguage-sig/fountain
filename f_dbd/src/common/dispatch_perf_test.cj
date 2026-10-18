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

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.io.InputStream
import std.reflect.TypeInfo
import std.time.MonoTime
import fountain::f_data.*
import fountain::f_data.base.*

/**
 * `QueryResultImpl.get<T>` / `getOrNull<T>` 的类型分派**性能前置实验**（`详细设计.md` §10.1，开发阻塞项）。
 *
 * 被测对象只有"类型判定 + 分支选择"两步：`Dispatch.canonicalA/B` 与 `Dispatch.reversedA/B` 接收
 * 同一份已解码 `Data`，返回命中分支的序号，**不做** `send`、`convert` 与任何 I/O
 * （故本用例不建网络、不落盘）。
 *
 * 两种候选：
 *
 * - **候选 A（`TypeInfo` + `isSubtypeOf`）**：每个具体类型的 `TypeInfo` 预缓存成 `TypeInfoCache` 的
 *   `static let`，热路径只有一次 `TypeInfo.of<T>()` + 若干次 `isSubtypeOf`；
 * - **候选 B（`None<T>` + `match case _: ?X`）**：`Option<T>` 的运行时类型**精确**匹配（泛型不变）。
 *
 * 用例矩阵（§10.1）：§8 全表 19 个类型 × {命中深度：canonical / reversed} × {命中 / 未命中}
 * + `getOrNull` 的 NULL 短路。
 */
@Test
public class GetDispatchPerfTest {

    /** 预热次数（§10.1 规定 ≥ 10⁴）。 */
    private static let WARMUP: Int64 = 10000
    /** 每轮计时循环次数（§10.1 规定 ≥ 10⁶）。 */
    private static let LOOPS: Int64 = 1000000
    /** 重复轮数，取中位数（§10.1 规定 ≥ 5）。 */
    private static let ROUNDS: Int64 = 5

    /**
     * §8 全表逐类型测量：canonical 与 reversed 两种分支顺序下，候选 A/B 的 ns/次（5 轮中位数）。
     *
     * canonical 顺序即 §8 表格顺序（`String` 在链首、`Duration` 在链尾）；reversed 完全倒序。
     * 同一类型在两种布局下的命中深度互补（深度 d 与 n+1-d），因此每个类型都得到"靠前的深度"与
     * "靠后的深度"两组数据；链首/链尾两个极端位置分别由 `String`/`Duration` 直接锚定。
     */
    @TestCase
    public func perTypeMatrix(): Unit {
        let rows = ArrayList<Row>()
        rows.add(measure<String>('String', 1))
        rows.add(measure<Rune>('Rune', 2))
        rows.add(measure<Bool>('Bool', 3))
        rows.add(measure<Int8>('Int8', 4))
        rows.add(measure<Int16>('Int16', 5))
        rows.add(measure<Int32>('Int32', 6))
        rows.add(measure<Int64>('Int64', 7))
        rows.add(measure<UInt8>('UInt8(Byte)', 8))
        rows.add(measure<UInt16>('UInt16', 9))
        rows.add(measure<UInt32>('UInt32', 10))
        rows.add(measure<UInt64>('UInt64', 11))
        rows.add(measure<Float32>('Float32', 12))
        rows.add(measure<Float64>('Float64', 13))
        rows.add(measure<Decimal>('Decimal', 14))
        rows.add(measure<BigInt>('BigInt', 15))
        rows.add(measure<Array<Byte>>('Array<Byte>', 16))
        rows.add(measure<InputStream>('InputStream', 17))
        rows.add(measure<DateTime>('DateTime', 18))
        rows.add(measure<Duration>('Duration', 19))

        println('')
        println('=== get<T> 类型分派性能实验：§8 全表逐类型（ns/次，5 轮中位数，10^6 次/轮） ===')
        println('| type | A/canonical | B/canonical | B:A | A/reversed | B/reversed | B:A |')
        for (row in rows) {
            println(row.toLine())
        }
        reportOverall('§8 全表逐类型', rows)
        assertWitnesses(rows)
    }

    /**
     * 未命中的成本：喂入不在表内的 `T`，两候选都必须走完整条链再落兜底。
     *
     * 该成本与具体 `T` 无关（都是"扫完整条链 + 兜底"），故以一组代表性未受支持的类型作探针；
     * 其中 `MyInputStream` 是 `InputStream` 的实现类 —— 它同时暴露两候选的**语义差异**。
     */
    @TestCase
    public func missProbes(): Unit {
        let rows = ArrayList<Row>()
        rows.add(measure<MissPlainClass>('Miss/plain class', 0))
        rows.add(measure<Array<String>>('Miss/Array<String>', 0))
        rows.add(measure<Option<Int64>>('Miss/?Int64', 0))
        rows.add(measure<ArrayList<Int64>>('Miss/ArrayList<Int64>', 0))
        rows.add(measure<IntNative>('Miss/IntNative', 0))

        println('')
        println('=== get<T> 类型分派性能实验：未命中探针（ns/次，5 轮中位数，10^6 次/轮） ===')
        println('| probe | A/canonical | B/canonical | B:A | A/reversed | B/reversed | B:A |')
        for (row in rows) {
            println(row.toLine())
        }
        reportOverall('未命中探针', rows)
        assertWitnesses(rows)
    }

    /**
     * `getOrNull<T>` 的 NULL 短路：`DataNone` 直接返回 `None<T>`、**不做任何类型分派**。
     *
     * 本用例量化"短路相对于完整分派省下的开销"：校验和随 `T` 固定，故每种 `T` 的累加值必须一致。
     */
    @TestCase
    public func nullShortCircuit(): Unit {
        let nothing = DataNone.INSTANCE
        let something = DataString('x')
        println('')
        println('=== getOrNull<T> 的 NULL 短路（ns/次，5 轮中位数，10^6 次/轮） ===')
        println('| T | 短路(DataNone) | 完整分派 A | 完整分派 B |')
        println(shortCircuitOf<Int64>('Int64', nothing, something))
        println(shortCircuitOf<String>('String', nothing, something))
        println(shortCircuitOf<DateTime>('DateTime', nothing, something))
        println(shortCircuitOf<Array<Byte>>('Array<Byte>', nothing, something))
        println(shortCircuitOf<MyInputStream>('MyInputStream', nothing, something))
    }

    /**
     * **语义差异（选型前必须先对齐）**：候选 A 用子类型匹配，候选 B 用 `Option<T>` 运行时精确匹配。
     *
     * 结果是：`T` 为 `InputStream` 的**实现类**时，A 命中 `InputStream` 分支（17）、B 落兜底（0）。
     * 这条用例把差异钉死 —— 无论性能结论如何，`get<T>` 的对外行为不得因选型而改变（§10.1 约束 1）。
     */
    @TestCase
    public func semanticDifferenceOnInterfaceImplementor(): Unit {
        @Assert(Dispatch.canonicalA<MyInputStream>(SAMPLE), 17i64)
        @Assert(Dispatch.canonicalB<MyInputStream>(SAMPLE), 0i64)
        @Assert(Dispatch.reversedA<MyInputStream>(SAMPLE), 17i64)
        @Assert(Dispatch.reversedB<MyInputStream>(SAMPLE), 0i64)
        @Assert(Dispatch.canonicalA<InputStream>(SAMPLE), 17i64)
        @Assert(Dispatch.canonicalB<InputStream>(SAMPLE), 17i64)
        // 别名 `Byte ≡ UInt8` 在两候选下都精确等价（泛型实参是同一个类型）
        @Assert(Dispatch.canonicalA<Byte>(SAMPLE), Dispatch.canonicalA<UInt8>(SAMPLE))
        @Assert(Dispatch.canonicalB<Byte>(SAMPLE), Dispatch.canonicalB<UInt8>(SAMPLE))
        // 其余 17 个类型在两候选下必须全部一致 —— 差异只出现在接口实现类这一处
        @Assert(Dispatch.canonicalA<MissPlainClass>(SAMPLE), Dispatch.canonicalB<MissPlainClass>(SAMPLE))
        @Assert(Dispatch.canonicalA<IntNative>(SAMPLE), Dispatch.canonicalB<IntNative>(SAMPLE))
        println('')
        println('=== 语义差异：T 为 InputStream 的实现类时，A 命中 17、B 落兜底 0 ===')
    }

    /** 单个类型 × 四种组合（A/B × canonical/reversed）的测量。 */
    private static func measure<T>(label: String, expected: Int64): Row {
        Row(label, expected, timedOrThrow<T>(Dispatch.canonicalA<T>, SAMPLE, expected),
            timedOrThrow<T>(Dispatch.canonicalB<T>, SAMPLE, expected),
            timedOrThrow<T>(Dispatch.reversedA<T>, SAMPLE, expected),
            timedOrThrow<T>(Dispatch.reversedB<T>, SAMPLE, expected))
    }

    /** NULL 短路与完整分派的三组对照。 */
    private static func shortCircuitOf<T>(label: String, nothing: Data, something: Data): String {
        let short = timed<T>(Dispatch.shortCircuitA<T>, nothing)
        let fullA = timed<T>(Dispatch.canonicalA<T>, something)
        let fullB = timed<T>(Dispatch.canonicalB<T>, something)
        '| ${label} | ${short.medianNsPerOp} | ${fullA.medianNsPerOp} | ${fullB.medianNsPerOp} |'
    }

    /**
     * 计时：先预热 `WARMUP` 次，再跑 `ROUNDS` 轮 × `LOOPS` 次，取每轮 ns/次的中位数。
     *
     * **防优化**：每一次分派的返回值都累加进 `witness`，由调用方在测试体内用 `@Assert` 校验其
     * 恰好等于 `expected × 迭代总数` —— 死代码消除一旦删掉分支选取，`witness` 就会对不上。
     */
    private static func timed<T>(dispatch: (Data) -> Int64, data: Data): Timing {
        var witness: Int64 = 0
        for (_ in 0..WARMUP) {
            witness += dispatch(data)
        }
        let perRound = Array<Int64>(ROUNDS, repeat: 0i64)
        for (r in 0..ROUNDS) {
            let start = MonoTime.now()
            var sum: Int64 = 0
            for (_ in 0..LOOPS) {
                sum += dispatch(data)
            }
            perRound[r] = (MonoTime.now() - start).toNanoseconds() / LOOPS
            witness += sum
        }
        Timing(medianOf(perRound), witness)
    }

    /** 同上，并当场断言防优化累加值等于 `expected × 迭代总数`。 */
    private static func timedOrThrow<T>(dispatch: (Data) -> Int64, data: Data,
        expected: Int64): Timing {
        let timing = timed<T>(dispatch, data)
        if (timing.witness != expected * (WARMUP + ROUNDS * LOOPS)) {
            throw IllegalStateException('dispatch witness mismatch: ${timing.witness}')
        }
        timing
    }

    /** `n` 个元素的中位数（就地排序后取中间）。 */
    private static func medianOf(ns: Array<Int64>): Int64 {
        let n = ns.size
        var i: Int64 = 0
        while (i < n - 1) {
            var j: Int64 = 0
            while (j < n - i - 1) {
                if (ns[j] > ns[j + 1]) {
                    let tmp = ns[j]
                    ns[j] = ns[j + 1]
                    ns[j + 1] = tmp
                }
                j += 1
            }
            i += 1
        }
        ns[n / 2]
    }

    /** 汇总并打印"合计 / 均值 / 最坏"三个视角的 A:B 比值，供 §10.1 的判定规则使用。 */
    private static func reportOverall(title: String, rows: ArrayList<Row>): Unit {
        var sumA: Int64 = 0
        var sumB: Int64 = 0
        var worstA: Int64 = 0
        var worstB: Int64 = 0
        for (row in rows) {
            sumA += row.aCanon + row.aRev
            sumB += row.bCanon + row.bRev
            worstA += largerOf(row.aCanon, row.aRev)
            worstB += largerOf(row.bCanon, row.bRev)
        }
        let n = rows.size * 2
        println('')
        println('--- ${title} 汇总 ---')
        println('  合计 ns/次: A=${sumA}  B=${sumB}   B:A=${formatPct(sumB, sumA)}')
        println('  均值 ns/次: A=${sumA / n}  B=${sumB / n}   B:A=${formatPct(sumB, sumA)}')
        println('  最坏 ns/次: A=${worstA}  B=${worstB}   B:A=${formatPct(worstB, worstA)}')
    }

    /** 防优化累加值必须与"命中序号 × 迭代总数"一致。 */
    private func assertWitnesses(rows: ArrayList<Row>): Unit {
        for (row in rows) {
            @Assert(row.aCanonWitness, row.expected * (WARMUP + ROUNDS * LOOPS))
            @Assert(row.bCanonWitness, row.expected * (WARMUP + ROUNDS * LOOPS))
            @Assert(row.aRevWitness, row.expected * (WARMUP + ROUNDS * LOOPS))
            @Assert(row.bRevWitness, row.expected * (WARMUP + ROUNDS * LOOPS))
        }
    }

    private static func largerOf(a: Int64, b: Int64): Int64 {
        if (a > b) {
            a
        } else {
            b
        }
    }

    /** 所有分派的同一份输入：一份已解码的、非 NULL 的单元格 `Data`。 */
    private static let SAMPLE: Data = DataString('x')
}

/** `b / a`，格式化成带两位小数的百分比字符串。 */
private func formatPct(b: Int64, a: Int64): String {
    if (a == 0) {
        '-'
    } else {
        let r = b * 10000 / a
        '${r / 100}.${(r % 100) / 10}${(r % 100) % 10}%'
    }
}

/** 候选未支持的类型：用于"未命中"探针（§10.1 用例矩阵）。 */
private class MissPlainClass {}

/** `InputStream` 的实现类：暴露候选 A（子类型匹配）与候选 B（精确匹配）的语义差异。 */
private class MyInputStream <: InputStream {
    public func read(_: Array<Byte>): Int64 {
        0
    }
}

/** 一次测量的结果：每轮 ns/次的中位数 + 防优化累加值。 */
private struct Timing {
    let medianNsPerOp: Int64
    let witness: Int64

    init(medianNsPerOp: Int64, witness: Int64) {
        this.medianNsPerOp = medianNsPerOp
        this.witness = witness
    }
}

/** 一个类型的一行结果：四种组合的 ns/次（中位数）与各自的防优化累加值。 */
private struct Row {
    let label: String
    let expected: Int64
    let aCanonWitness: Int64
    let bCanonWitness: Int64
    let aRevWitness: Int64
    let bRevWitness: Int64
    let aCanon: Int64
    let bCanon: Int64
    let aRev: Int64
    let bRev: Int64

    init(label: String, expected: Int64, canA: Timing, canB: Timing, revA: Timing, revB: Timing) {
        this.label = label
        this.expected = expected
        this.aCanonWitness = canA.witness
        this.bCanonWitness = canB.witness
        this.aRevWitness = revA.witness
        this.bRevWitness = revB.witness
        this.aCanon = canA.medianNsPerOp
        this.bCanon = canB.medianNsPerOp
        this.aRev = revA.medianNsPerOp
        this.bRev = revB.medianNsPerOp
    }

    func toLine(): String {
        '| ${label} | ${aCanon} | ${bCanon} | ${formatPct(bCanon, aCanon)} | ${aRev} | ${bRev} | ${formatPct(bRev, aRev)} |'
    }
}

/**
 * 候选 A 预缓存的具体类型 `TypeInfo`（§10.1 约束 2：热路径只允许一次 `TypeInfo.of<T>()`，
 * 具体类型的 `TypeInfo` 一律来自这里的 `static let`）。
 */
private struct TypeInfoCache {
    static let STRING = TypeInfo.of<String>()
    static let RUNE = TypeInfo.of<Rune>()
    static let BOOL = TypeInfo.of<Bool>()
    static let INT8 = TypeInfo.of<Int8>()
    static let INT16 = TypeInfo.of<Int16>()
    static let INT32 = TypeInfo.of<Int32>()
    static let INT64 = TypeInfo.of<Int64>()
    static let UINT8 = TypeInfo.of<UInt8>()
    static let UINT16 = TypeInfo.of<UInt16>()
    static let UINT32 = TypeInfo.of<UInt32>()
    static let UINT64 = TypeInfo.of<UInt64>()
    static let FLOAT32 = TypeInfo.of<Float32>()
    static let FLOAT64 = TypeInfo.of<Float64>()
    static let DECIMAL = TypeInfo.of<Decimal>()
    static let BIG_INT = TypeInfo.of<BigInt>()
    static let BYTE_ARRAY = TypeInfo.of<Array<Byte>>()
    static let INPUT_STREAM = TypeInfo.of<InputStream>()
    static let DATE_TIME = TypeInfo.of<DateTime>()
    static let DURATION = TypeInfo.of<Duration>()
}

/**
 * 两候选的分派实现（canonical / reversed 两种分支顺序）。
 *
 * 返回值是命中分支的序号（`1..19`，即 §8 表序），未命中返回 `0` —— 既能在调用端累加
 * （防死代码消除），又能用来核对两候选的语义是否一致。
 */
private struct Dispatch {

    /** 候选 A（canonical 顺序）：`TypeInfo.of<T>()` + 预缓存常量的 `isSubtypeOf`。 */
    static func canonicalA<T>(_: Data): Int64 {
        let ti = TypeInfo.of<T>()
        if (ti.isSubtypeOf(TypeInfoCache.STRING)) {
            1
        } else if (ti.isSubtypeOf(TypeInfoCache.RUNE)) {
            2
        } else if (ti.isSubtypeOf(TypeInfoCache.BOOL)) {
            3
        } else if (ti.isSubtypeOf(TypeInfoCache.INT8)) {
            4
        } else if (ti.isSubtypeOf(TypeInfoCache.INT16)) {
            5
        } else if (ti.isSubtypeOf(TypeInfoCache.INT32)) {
            6
        } else if (ti.isSubtypeOf(TypeInfoCache.INT64)) {
            7
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT8)) {
            8
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT16)) {
            9
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT32)) {
            10
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT64)) {
            11
        } else if (ti.isSubtypeOf(TypeInfoCache.FLOAT32)) {
            12
        } else if (ti.isSubtypeOf(TypeInfoCache.FLOAT64)) {
            13
        } else if (ti.isSubtypeOf(TypeInfoCache.DECIMAL)) {
            14
        } else if (ti.isSubtypeOf(TypeInfoCache.BIG_INT)) {
            15
        } else if (ti.isSubtypeOf(TypeInfoCache.BYTE_ARRAY)) {
            16
        } else if (ti.isSubtypeOf(TypeInfoCache.INPUT_STREAM)) {
            17
        } else if (ti.isSubtypeOf(TypeInfoCache.DATE_TIME)) {
            18
        } else if (ti.isSubtypeOf(TypeInfoCache.DURATION)) {
            19
        } else {
            0
        }
    }

    /** 候选 B（canonical 顺序）：`None<T>` + `match case _: ?X`。 */
    static func canonicalB<T>(_: Data): Int64 {
        let probe: ?T = None<T>
        match (probe) {
            case _: ?String => 1
            case _: ?Rune => 2
            case _: ?Bool => 3
            case _: ?Int8 => 4
            case _: ?Int16 => 5
            case _: ?Int32 => 6
            case _: ?Int64 => 7
            case _: ?UInt8 => 8
            case _: ?UInt16 => 9
            case _: ?UInt32 => 10
            case _: ?UInt64 => 11
            case _: ?Float32 => 12
            case _: ?Float64 => 13
            case _: ?Decimal => 14
            case _: ?BigInt => 15
            case _: ?Array<Byte> => 16
            case _: ?InputStream => 17
            case _: ?DateTime => 18
            case _: ?Duration => 19
            case _ => 0
        }
    }

    /** 候选 A（reversed 顺序）：同一组分支，判定顺序完全倒过来。 */
    static func reversedA<T>(_: Data): Int64 {
        let ti = TypeInfo.of<T>()
        if (ti.isSubtypeOf(TypeInfoCache.DURATION)) {
            19
        } else if (ti.isSubtypeOf(TypeInfoCache.DATE_TIME)) {
            18
        } else if (ti.isSubtypeOf(TypeInfoCache.INPUT_STREAM)) {
            17
        } else if (ti.isSubtypeOf(TypeInfoCache.BYTE_ARRAY)) {
            16
        } else if (ti.isSubtypeOf(TypeInfoCache.BIG_INT)) {
            15
        } else if (ti.isSubtypeOf(TypeInfoCache.DECIMAL)) {
            14
        } else if (ti.isSubtypeOf(TypeInfoCache.FLOAT64)) {
            13
        } else if (ti.isSubtypeOf(TypeInfoCache.FLOAT32)) {
            12
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT64)) {
            11
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT32)) {
            10
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT16)) {
            9
        } else if (ti.isSubtypeOf(TypeInfoCache.UINT8)) {
            8
        } else if (ti.isSubtypeOf(TypeInfoCache.INT64)) {
            7
        } else if (ti.isSubtypeOf(TypeInfoCache.INT32)) {
            6
        } else if (ti.isSubtypeOf(TypeInfoCache.INT16)) {
            5
        } else if (ti.isSubtypeOf(TypeInfoCache.INT8)) {
            4
        } else if (ti.isSubtypeOf(TypeInfoCache.BOOL)) {
            3
        } else if (ti.isSubtypeOf(TypeInfoCache.RUNE)) {
            2
        } else if (ti.isSubtypeOf(TypeInfoCache.STRING)) {
            1
        } else {
            0
        }
    }

    /** 候选 B（reversed 顺序）：同一组分支，判定顺序完全倒过来。 */
    static func reversedB<T>(_: Data): Int64 {
        let probe: ?T = None<T>
        match (probe) {
            case _: ?Duration => 19
            case _: ?DateTime => 18
            case _: ?InputStream => 17
            case _: ?Array<Byte> => 16
            case _: ?BigInt => 15
            case _: ?Decimal => 14
            case _: ?Float64 => 13
            case _: ?Float32 => 12
            case _: ?UInt64 => 11
            case _: ?UInt32 => 10
            case _: ?UInt16 => 9
            case _: ?UInt8 => 8
            case _: ?Int64 => 7
            case _: ?Int32 => 6
            case _: ?Int16 => 5
            case _: ?Int8 => 4
            case _: ?Bool => 3
            case _: ?Rune => 2
            case _: ?String => 1
            case _ => 0
        }
    }

    /** `getOrNull<T>` 的 NULL 短路：`DataNone` 直接返回，**不分派**。 */
    static func shortCircuitA<T>(data: Data): Int64 {
        if (data is DataNone) {
            0
        } else {
            Dispatch.canonicalA<T>(data)
        }
    }
}
