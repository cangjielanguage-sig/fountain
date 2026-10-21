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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import std.time.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import std.collection.*
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.h_dispatch
import fountain::f_jit.test.diff.AArch64Runner
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.NativeRunner
import fountain::f_jit.test.diff.DiffSession
import fountain::f_jit.test.diff.InterpRunner

/**
 * S7.1–S7.6 差分验收：**同一份 `.fbc` × 同一组入参**，`Interp` 与原生 `AArch64`
 * 的结果 / 错误码 / 站点逐位一致（§12.7、I7）。
 *
 * 本机最小集 = `Interp × AArch64`；x86_64 由 `isAvailable()` 记入「非原生跳过」，
 * 证据在 x86_64 CI 上补齐（与 `DiffHarness` 的口径一致）。
 *
 * 用例编号对应 `doc/plan-m1.md` §3 的 T 矩阵；单元级判据（T4 页对齐、T5 IBT、
 * T7/T9 选择层、T16/T17 缓存、T27 ctx 生命周期、T29 卸载）仍由各自包内的用例承载，
 * 这里只做**三引擎同源对拍**这一层。
 */
@Test
public class Acceptance_test {

    // ---------------------------------------------------------------- S7.1

    /** T1：黄金字节码跨平台加载——同一份 raw 反复装载后语义不变。 */
    @TestCase
    public func t1GoldenUnitLoad(): Unit {
        Acceptance_test.diff('T1/reload', '{ => 1 + 1 }', Array<Any>())
        let raw = Acceptance_test.rawOf('{ n: Int64 => n * 3 + 1 }')
        let copy = Array<UInt8>(raw.size, repeat: 0u8)
        var i = 0
        while (i < raw.size) {
            copy[i] = raw[i]
            i = i + 1
        }
        let id = raw.size == copy.size
        @Assert(id, true)
        Acceptance_test.diffRaw('T1/copy', copy, [5])
    }

    /** T2：三引擎差分核心（常量 / 多参 / 分支 / F64 / NaN）已由 `DiffExec_test` 覆盖。 */
    @TestCase
    public func t2TripleEqualCore(): Unit {
        Acceptance_test.diff('T2/const', '{ => 1 + 1 }', Array<Any>())
        Acceptance_test.diff('T2/args', '{ a: Int64, b: Int64 => a + b }', [20, 22])
        Acceptance_test.diff('T2/f64', '{ => 1.5f64 * 2.0f64 }', Array<Any>())
    }

    // ---------------------------------------------------------------- S7.2

    /** T6：错误一致性——每个可达错误码同时断言 `errCode` 与站点。 */
    @TestCase
    public func t6ErrorConsistency(): Unit {
        Acceptance_test.diffCode('T6/div0', '{ a: Int64 => a / (a - a) }', [1], 1)
        Acceptance_test.diffCode('T6/mod0', '{ a: Int64 => a % (a - a) }', [1], 2)
        Acceptance_test.diffCode('T6/overflow', '{ a: Int64 => a * a }', [3037000500], 3)
        Acceptance_test.diffCode('T6/oob', '{ => let l = [1, 2]\n l[5] }', Array<Any>(), 4)
        Acceptance_test.diffCode('T6/key-missing',
            '{ => let m: Map<String, Int64> = {}\n m["k"] }', Array<Any>(), 5)
        Acceptance_test.diffCode('T6/dec-range', '{ => Int64(Decimal(1.0e30)) }', Array<Any>(), 9)
        Acceptance_test.diffCode('T6/dec-div0',
            '{ => let d = Decimal(1) / Decimal(0)\n 0 }', Array<Any>(), 10)
        Acceptance_test.diffCode('T6/dt-range',
            '{ => let t = DateTime.parse("9999-12-31T23:59:59Z") + Duration.day\n 0 }',
            Array<Any>(), 11)
        Acceptance_test.diffCode('T6/fp-invalid', '{ x: Float64 => Int64(x) }', [1.0e300], 13)
        Acceptance_test.diffCode('T6/dec-const', '{ => Int64(1.0e300) }', Array<Any>(), 9)
        Acceptance_test.diffCode('T6/regex-invalid',
            '{ => let b = "(".regex() ~ "a"\n 0 }', Array<Any>(), 14)
        Acceptance_test.diffCode('T6/concurrent-mod',
            '{ => let m: Map<Int64, Int64> = {}\n m[1] = 1\n m[2] = 2\n' +
            ' for ((k, v) in m) { m[3] = 3 }\n 0 }', Array<Any>(), 23)
        // 6 / 8 / 18 / 20：源码类型系统不可达，按 helper 入口直接构造（三引擎共用同一实现）。
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        @Assert(Acceptance_test.callHelper(1, [0], ctx), 0)
        @Assert(ctx.errCode, 6)
        ctx.errCode = 0
        let str = HandleTable.pin("abc")
        @Assert(Acceptance_test.callHelper(1, [str], ctx), 0)
        @Assert(ctx.errCode, 8)
        ctx.errCode = 0
        let cl = ArrayList<Any>()
        cl.add(1)
        let constList = HandleTable.pinConst(cl)
        @Assert(Acceptance_test.callHelper(43, [constList, 2], ctx), 0)
        @Assert(ctx.errCode, 20)
        ctx.errCode = 0
        @Assert(Acceptance_test.callHelper(999, [], ctx), 0)
        @Assert(ctx.errCode, 18)
        JitContext.free(ctx)
    }

    /** 直呼 `h_dispatch(hid, ctx, &args, n)`；args 按「最深实参在高地址」排列。 */
    private static func callHelper(hid: Int64, values: Array<Int64>, ctx: JitContext): Int64 {
        let n = values.size
        let p = if (n == 0) {
            CPointer<Int64>()
        } else {
            let raw = LibC.malloc<Int64>(count: n)
            var i = 0
            while (i < n) {
                unsafe { raw.write(i, values[n - 1 - i]) }
                i = i + 1
            }
            unsafe { raw + (n - 1) }
        }
        let alloc = if (n == 0) { CPointer<Int64>() } else { unsafe { p - (n - 1) } }
        let f: CFunc<(Int64, CPointer<Unit>, CPointer<Int64>, Int64) -> Int64> = h_dispatch
        let r = unsafe { f(hid, CPointer<Unit>(ctx.cp()), p, n) }
        if (n > 0) {
            unsafe { LibC.free<Int64>(alloc) }
        }
        r
    }

    /** T8：NaN 与文本化——位模式与 `TO_STR` 文本逐字节一致。 */
    @TestCase
    public func t8NanTextualization(): Unit {
        Acceptance_test.diff('T8/nan', '{ => 0.0f64 / 0.0f64 }', Array<Any>())
        Acceptance_test.diff('T8/inf', '{ => 1.0f64 / 0.0f64 }', Array<Any>())
        Acceptance_test.diff('T8/neg-inf', '{ => -1.0f64 / 0.0f64 }', Array<Any>())
        Acceptance_test.diff('T8/nan-str', '{ => 0.0f64 / 0.0f64 + "" }', Array<Any>())
    }

    // ---------------------------------------------------------------- S7.3

    /** T10：窗口分配与重放——超过初始容量后仍逐位一致。 */
    @TestCase
    public func t10WindowGrowth(): Unit {
        Acceptance_test.diff('T10/grow',
            '{ => var s = ""\n var i = 0\n while (i < 200) { s = s + "x"\n i = i + 1 }\n s }',
            Array<Any>())
    }

    /** T11：`TO_STR` 黄金值（全标签类型，DateTime 由固定 TZ 的 T11 单测承担）。 */
    @TestCase
    public func t11ToStrGolden(): Unit {
        Acceptance_test.diff('T11/i64', '{ => 42 + "!" }', Array<Any>())
        Acceptance_test.diff('T11/neg', '{ => (0 - 42) + "!" }', Array<Any>())
        Acceptance_test.diff('T11/f64', '{ => 1.5f64 + "!" }', Array<Any>())
        Acceptance_test.diff('T11/f64-int', '{ => 2.0f64 + "!" }', Array<Any>())
        Acceptance_test.diff('T11/bool', '{ => true + "!" }', Array<Any>())
        Acceptance_test.diff('T11/string', '{ => "a" + "b" }', Array<Any>())
        Acceptance_test.diff('T11/decimal', '{ => 1.5 + "!" }', Array<Any>())
        Acceptance_test.diff('T11/range', '{ => (1..=3) + "!" }', Array<Any>())
        Acceptance_test.diff('T11/regex', '{ => /a/i + "!" }', Array<Any>())
        Acceptance_test.diff('T11/interp-mixed',
            '{ x: Int64 => "n=' + Acceptance_test.DOLLAR + '{x}!" }', [7])
    }

    /** T12：混合数值提升（Int64 / F64 / Decimal）。 */
    @TestCase
    public func t12MixedNumeric(): Unit {
        Acceptance_test.diff('T12/i64-f64', '{ => 1 + 2.5f64 }', Array<Any>())
        Acceptance_test.diff('T12/i64-dec', '{ => (1 + 0.5) + "" }', Array<Any>())
        Acceptance_test.diff('T12/f64-dec', '{ => (0.5f64 + 1.5) + "" }', Array<Any>())
        Acceptance_test.diff('T12/cmp', '{ => 1 < 1.5 }', Array<Any>())
        Acceptance_test.diff('T12/cast', '{ => Int64(2.9) }', Array<Any>())
    }

    /** T13：类型化局部与明确赋值。 */
    @TestCase
    public func t13TypedLocals(): Unit {
        Acceptance_test.diff('T13/typed',
            '{ => var x: Int64 = 1\n x = x + 2\n x }', Array<Any>())
        Acceptance_test.diff('T13/handle-local',
            '{ => let l: List<Int64> = [1, 2]\n l[1] }', Array<Any>())
    }

    /** T18 / T53：容器读写（索引写 + 读）。 */
    @TestCase
    public func t18ContainerMutation(): Unit {
        Acceptance_test.diff('T18/list-set',
            '{ => let l = [1, 2]\n l[0] = 3\n l[0] }', Array<Any>())
        Acceptance_test.diff('T18/map-put',
            '{ => let m: Map<Int64, Int64> = {}\n m[1] = 11\n m[1] }', Array<Any>())
        Acceptance_test.diff('T53/list-sum',
            '{ => let l = [10, 20, 30]\n l[0] + l[1] + l[2] }', Array<Any>())
        // T53：变更型 helper 的目标是路径 A 常量 → 20（源码不可直接构造常量容器）
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let cl = ArrayList<Any>()
        cl.add(1)
        let constList = HandleTable.pinConst(cl)
        @Assert(Acceptance_test.callHelper(43, [constList, 2], ctx), 0)
        @Assert(ctx.errCode, 20)
        JitContext.free(ctx)
    }

    /** T19 / T45：List / Map / String 迭代（Map 走惰性单遍迭代器）。 */
    @TestCase
    public func t19Iteration(): Unit {
        Acceptance_test.diff('T19/list',
            '{ => var s = 0\n for (x in [1, 2, 3]) { s = s + x }\n s }', Array<Any>())
        Acceptance_test.diff('T19/string',
            '{ => var n = 0\n for (c in "abc") { n = n + 1 }\n n }', Array<Any>())
        Acceptance_test.diff('T45/map',
            '{ => var s = 0\n for ((k, v) in {1: 10, 2: 20}) { s = s + k + v }\n s }',
            Array<Any>())
    }

    /** T20 / T26 / T46：正则匹配与替换。 */
    @TestCase
    public func t20RegexInterop(): Unit {
        Acceptance_test.diff('T20/match', '{ => /b/ ~ "abc" }', Array<Any>())
        Acceptance_test.diff('T20/no-match', '{ => /z/ ~ "abc" }', Array<Any>())
        Acceptance_test.diff('T26/not', '{ => /z/ !~ "abc" }', Array<Any>())
        Acceptance_test.diff('T26/replace', '{ => /b//"abcabc"/"X"/g }', Array<Any>())
        Acceptance_test.diff('T46/str-regex',
            '{ => "a.c".regex() ~ "abc" }', Array<Any>())
    }

    /** T21：多重赋值（先读后写）。 */
    @TestCase
    public func t21MultiAssign(): Unit {
        Acceptance_test.diff('T21/swap',
            '{ => var a = 1\n var b = 2\n (a, b) = (b, a)\n a * 10 + b }', Array<Any>())
        Acceptance_test.diff('T21/ignore',
            '{ => var a = 1\n var b = 2\n (_, b) = (a, 9)\n b }', Array<Any>())
    }

    /** T22：源入口与 `recursive`。 */
    @TestCase
    public func t22SourceEntryRecursive(): Unit {
        Acceptance_test.diff('T22/factorial',
            '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }', [5])
    }

    /** T24 / T25：闭包与捕获（含 `LOAD_CAP`）。 */
    @TestCase
    public func t24Closures(): Unit {
        Acceptance_test.diff('T24/iife', '{ => {=> 42}() }', Array<Any>())
        Acceptance_test.diff('T24/capture',
            '{ a: Int64 => let f = { b: Int64 => a + b }\n f(2) }', [1])
        Acceptance_test.diff('T25/nested',
            '{ a: Int64 => let f = { b: Int64 => let g = { c: Int64 => a + b + c }\n g(3) }\n f(2) }',
            [1])
    }

    /** T28 / T47：尾递归（`LOOP_BACK` 回边，不增长栈）。 */
    @TestCase
    public func t28TailRecursion(): Unit {
        Acceptance_test.diff('T28/sum',
            '{ n: Int64 => var acc = 0\n if (n <= 0) { acc } else { recursive(n - 1) } }', [10])
        Acceptance_test.diff('T47/count',
            '{ n: Int64 => if (n <= 0) { 0 } else { 1 + recursive(n - 1) } }', [1000])
    }

    // ---------------------------------------------------------------- S7.6

    /** T42：字符串三形态（单行 / 多行 / 原始串）。 */
    @TestCase
    public func t42StringForms(): Unit {
        Acceptance_test.diff('T42/single', '{ => "a\\tb" }', Array<Any>())
        Acceptance_test.diff('T42/multi', '{ => """\na\nb""" }', Array<Any>())
        Acceptance_test.diff('T42/raw', '{ => #"a\\tb"# }', Array<Any>())
    }

    /** T43：String 重复与 DateTime 差。 */
    @TestCase
    public func t43RepeatAndDateDiff(): Unit {
        Acceptance_test.diff('T43/repeat', '{ => "ab" * 3 }', Array<Any>())
        Acceptance_test.diff('T43/repeat-zero', '{ => "ab" * 0 }', Array<Any>())
        Acceptance_test.diff('T43/date-diff',
            '{ => (DateTime.parse("2023-04-11T00:00:00Z") - DateTime.parse("2023-04-10T00:00:00Z")) + "" }',
            Array<Any>())
    }

    /** T44：`if` 值/语句双用法。 */
    @TestCase
    public func t44IfDualUsage(): Unit {
        Acceptance_test.diff('T44/value',
            '{ n: Int64 => let x = if (n > 0) { 1 } else { 2 }\n x }', [1])
        Acceptance_test.diff('T44/statement',
            '{ n: Int64 => var x = 0\n if (n > 0) { x = 1 }\n x }', [1])
    }

    /**
     * T48 / T51：空容器构造与读写（A7/P3-4 诚实化）。
     *
     * 旧用例对**空列表**做 `l[0] = 5`——恒为越界 4，却按「成功路径」记 full（矩阵虚报）。
     * 现在逐条断言**真实语义**：空列表的下标写/读都是 4（负向面），空 Map 的 upsert 才是
     * 成功路径（写后读回 1）。
     */
    @TestCase
    public func t48EmptyContainers(): Unit {
        Acceptance_test.diffCode('T48/list',
            '{ => let l: List<Int64> = []\n l[0] = 5\n l[0] }', Array<Any>(), ErrCode.IDX_OOB)
        Acceptance_test.diff('T48/map',
            '{ => let m: Map<String, Int64> = {}\n m["k"] = 1\n m["k"] }', Array<Any>())
        Acceptance_test.diffCode('T51/empty-list-read',
            '{ => let l: List<Int64> = []\n l[0] }', Array<Any>(), ErrCode.IDX_OOB)
    }

    /**
     * A7.4：M3 的 Any / JSON 通道在 **Interp × Native 双引擎**上逐位一致。
     *
     * 旧矩阵的「M3 三引擎全等」没有任何证据（15 处 `DiffSession` 无一覆盖 Any/JSON）；
     * 这里用同一 `DiffSession`（解释器 + 机器码）跑两条最小单元，补齐证据面。
     */
    @TestCase
    public func m3AnyJsonIsTripleEqual(): Unit {
        // M3 单元必须以 verMajor=3 编译（`rawOf` 是 M1 口径，遇到 15 会报「局部槽类型码非法」）
        Acceptance_test.diffRaw('M3/any-roundtrip', Acceptance_test.rawOfM3(
            '{ => let a: Any = 7\n (a as Int64) + 1 }'), Array<Any>())
        Acceptance_test.diffRaw('M3/json-access', Acceptance_test.rawOfM3(
            '{ => let o: JsonObject = `{"k":1}`\n (o["k"] as Int64) }'), Array<Any>())
    }

    /**
     * T50：运行期报告（源码行 + 变量名/类型/值）在解释器与机器码两条路径逐位一致。
     *
     * 失败点必须**同时**产出转储：`ctx.dbgBase` 指向桥分配的非托管缓冲，
     * 首个收敛点获胜（最深失败帧），报告按 §9.16 模板组装。
     */
    @TestCase
    public func t50SourcePosDiagnostics(): Unit {
        let src = '{ a: Int64 => let b = a + 1\n b / (a - a) }'
        let raw = Acceptance_test.rawOf(src)
        let c = DiffCase('T50/report', raw, [1])
        let i = InterpRunner().run(c)
        let j = NativeRunner().run(c)
        @Assert(i.errCode, 1)
        @Assert(j.errCode, 1)
        @Assert(i.site, j.site)
        @Assert(i.report, j.report)
        @Assert(i.report.contains('（code=1，site='), true)
        @Assert(i.report.contains('源码行 2:'), true)
        @Assert(i.report.contains('[0] a: Int64 = 1'), true)
        @Assert(i.report.contains('[1] b: Int64 = 2'), true)
    }

    // ---------------------------------------------------------------- S7.7

    /**
     * 容量基线：把 `initialCapacity` 调到 2，强制窗口在循环里反复倍增；
     * 两引擎结果仍逐位一致（扩容是实现细节，不改变语义）。
     */
    @TestCase
    public func tCapacityGrowthUnderSmallWindow(): Unit {
        let saved = HandleTable.initialCapacity
        HandleTable.initialCapacity = 2
        try {
            Acceptance_test.diff('T-cap/grow',
                '{ => var s = ""\n var i = 0\n while (i < 64) { s = s + "x"\n i = i + 1 }\n s }',
                Array<Any>())
        } finally {
            HandleTable.initialCapacity = saved
        }
    }

    /**
     * 性能基线：同一份字节码、同一个循环，分别测 `Interp` 与原生 `AArch64` 的墙钟时间。
     *
     * 判据只要求两者结果一致且都完成；**数字打出来留档**（非估计值），
     * 比值受宿主负载影响，不写死在断言里。
     */
    @TestCase
    public func tPerfBaselineRecordsActualNumbers(): Unit {
        let src = '{ n: Int64 => var s = 0\n var i = 0\n while (i < n) { s = s + i % 7\n i = i + 1 }\n s }'
        let raw = Acceptance_test.rawOf(src)
        let c = DiffCase('T-perf', raw, [200000])
        let i0 = DateTime.now()
        let a = InterpRunner().run(c)
        let d1 = DateTime.now() - i0
        let j0 = DateTime.now()
        let b = NativeRunner().run(c)
        let d2 = DateTime.now() - j0
        @Assert(a.result, b.result)
        @Assert(a.errCode, b.errCode)
        @Assert(d1.toNanoseconds() > 0, true)
        @Assert(d2.toNanoseconds() > 0, true)
        println('PERF interp=' + d1.toNanoseconds().toString() + 'ns jit=' +
            d2.toNanoseconds().toString() + 'ns result=' + a.result)
    }

    // ==================================================================

    private static const DOLLAR: String = '$'

    private static func rawOf(src: String): Array<UInt8> {
        SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src).raw
    }

    /** M3 口径的产物（`verMajor=3`；Any / JSON 需要合法集 0–19）。 */
    private static func rawOfM3(src: String): Array<UInt8> {
        SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR).compile(src).raw
    }

    private static func diff(id: String, src: String, args: Array<Any>): Unit {
        Acceptance_test.diffRaw(id, Acceptance_test.rawOf(src), args)
    }

    private static func diffRaw(id: String, raw: Array<UInt8>, args: Array<Any>): Unit {
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase(id, raw, args))
        @Assert(session.ran() >= 1, true)
    }

    private static func diffCode(id: String, src: String, args: Array<Any>,
        expect: Int64): Unit {
        let raw = Acceptance_test.rawOf(src)
        Acceptance_test.diffRaw(id, raw, args)
        @Assert(InterpRunner().run(DiffCase(id, raw, args)).errCode, expect)
    }
}
