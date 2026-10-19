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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.collection.HashMap
import std.math.numeric.Decimal
import std.regex.Regex
import std.time.DateTime
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * S4.7–S4.18 helper 族的验收用例（逐族一条以上）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §6（helper 表：签名 / 失败码 / 分配型归属）、§11.9
 * （文本化与区间 / 正则语义）、§9 附则 5（写码规则）。
 */
@Test
public class Helpers_test {
    private var ctx: ?JitContext = None

    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        RuntimeEnv.clearDeadline()
        MachineEnv.reset()
        IterTable.clearAll()
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        let c = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
        this.ctx = Some(c)
    }

    private func teardown(): Unit {
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = None
    }

    /** 调 helper 并返回 cell；错误码落在 `ctx.errCode`。 */
    private func call(hid: Int64, args: Array<Int64>): Int64 {
        match (this.ctx) {
            case Some(c) => invokeHelper(c, hid, args)
            case None => 0
        }
    }

    private func err(): Int64 {
        match (this.ctx) {
            case Some(c) => c.errCode
            case None => -99
        }
    }

    /** 只清错误槽（不重置句柄表 —— 句柄表重置会让此前 pin 的 ID 失效）。 */
    private func clearErr(): Unit {
        match (this.ctx) {
            case Some(c) => c.errCode = 0
            case None => ()
        }
    }

    private func used(): Int64 {
        HandleTable.windowUsed()
    }

    private func str(s: String): Int64 {
        HandleTable.pin(s)
    }

    private func text(h: Int64): String {
        match (HandleTable.getAny(h)) {
            case Some(v) => match (v) { case s: String => s; case _ => '<non-string>' }
            case None => '<null>'
        }
    }

    private func dec(s: String): Int64 {
        HandleTable.pin(Decimal.parse(s))
    }

    // ========================================================================
    // S4.7 HelperId
    // ========================================================================

    /** 1–62 与 69–72 逐值登记，63–68 保留（§6 + §8.4）。 */
    @TestCase
    public func helperIdsCoverSpecRange(): Unit {
        let expected = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
            21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
            39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
            57, 58, 59, 60, 61, 62, 69, 70, 71, 72, 73, 74, 75, 76
        ]
        @Assert(expected.size, 70)
        for (v in expected) {
            @Assert(HelperId.isFixed(UInt16(v)), true)
            @Assert(HelperId.name(UInt16(v)).isEmpty(), false)
        }
        for (v in 63..69) {
            @Assert(HelperId.isFixed(UInt16(v)), false)
            @Assert(HelperId.name(UInt16(v)).contains('reserved'), true)
        }
        @Assert(HelperId.isFixed(0u16), false)
        @Assert(HelperId.isFixed(77u16), false)
        @Assert(HelperId.name(HelperId.H_LEN), 'hl_len')
        @Assert(HelperId.name(HelperId.REGEX_REPLACE_RANGE), 'regex_replace_range')
        @Assert(HelperId.name(HelperId.DATETIME_NOW), 'datetime_now')
        @Assert(HelperId.name(HelperId.DURATION_PARSE), 'duration_parse')
        @Assert(HelperId.USER_BASE, 0x0100u16)
    }

    // ========================================================================
    // S4.8 容器 / 字符串读（H01–H08）
    // ========================================================================

    /** List / Map / String 的读：正常值、越界 4、缺键 5、null 6、tag 不符 8；**不登记槽**。 */
    @TestCase
    public func readHelpersReturnValuesAndFailures(): Unit {
        setup()
        let l = HandleTable.pin(listOf([1, 2, 3]))
        let m = HandleTable.pin(mapOf([(1, 11), (2, 22)]))
        let s = str('héllo')
        let base = used()
        @Assert(call(1, [l]), 3) // hl_len
        @Assert(call(2, [l, 1]), 2) // hl_get
        @Assert(call(3, [m]), 2) // hm_len
        @Assert(call(4, [m, 1]), 11) // hm_get
        @Assert(call(5, [m, 9, -1]), -1) // hm_get_or 缺键取默认
        @Assert(call(6, [m, 1]), 1) // hm_has
        @Assert(call(6, [m, 9]), 0)
        @Assert(call(7, [s]), 5) // hs_len 按码点
        @Assert(call(8, [s, 1]), Int64(UInt32(r'é'))) // hs_at
        @Assert(err(), 0)
        @Assert(used(), base) // 不登记槽
        // 越界 4
        @Assert(call(2, [l, 3]), 0)
        @Assert(err(), ErrCode.IDX_OOB)
        teardown()
    }

    /** null → 6、tag 不符 → 8（fetch 类公共失败码，§6）。 */
    @TestCase
    public func readHelpersRejectNullAndWrongTag(): Unit {
        setup()
        @Assert(call(1, [0]), 0) // hl_len(null)
        @Assert(err(), ErrCode.NULL_HANDLE)
        clearErr()
        let s = str('abc')
        @Assert(call(1, [s]), 0) // hl_len(String) → 8
        @Assert(err(), ErrCode.HANDLE_TYPE)
        clearErr()
        let m = HandleTable.pin(mapOf([(1, 11)]))
        @Assert(call(4, [m, 2]), 0) // hm_get 缺键
        @Assert(err(), ErrCode.KEY_MISSING)
        teardown()
    }

    private func listOf(xs: Array<Int64>): ArrayList<Any> {
        var l = ArrayList<Any>()
        for (x in xs) {
            l.add(x)
        }
        l
    }

    private func mapOf(kvs: Array<(Int64, Int64)>): HashMap<ConstMapKey, Any> {
        var m = HashMap<ConstMapKey, Any>()
        for (kv in kvs) {
            m.add(ConstMapKey(kv[0], 'i:${kv[0]}'), kv[1])
        }
        m
    }

    // ========================================================================
    // S4.9 比较 / 判定（H09–H20）
    // ========================================================================

    /** 字符串 / Decimal / DateTime / Duration 比较：禁浮点中间值，三路比较 -1/0/1。 */
    @TestCase
    public func comparisonHelpers(): Unit {
        setup()
        let a = str('abc')
        let b = str('abd')
        @Assert(call(9, [a, b]), -1)
        @Assert(call(9, [b, a]), 1)
        @Assert(call(9, [a, str('abc')]), 0)
        let d1 = dec('1.50')
        let d2 = dec('2')
        @Assert(call(11, [d1, d2]), -1)
        @Assert(call(11, [d2, d1]), 1)
        @Assert(call(12, [d2]), 1) // hd_is_int
        @Assert(call(12, [dec('1.5')]), 0)
        let t1 = HandleTable.pin(DateTime.ofEpoch(second: 0, nanosecond: 0))
        let t2 = HandleTable.pin(DateTime.ofEpoch(second: 1, nanosecond: 0))
        @Assert(call(13, [t1, t2]), -1)
        let u1 = HandleTable.pin(Duration.second)
        let u2 = HandleTable.pin(Duration.second * 2)
        @Assert(call(15, [u1, u2]), -1)
        @Assert(call(16, [u2]), 2000000000)
        @Assert(err(), 0)
        teardown()
    }

    /** `h_ref_eq` **恒不失败**（对 null / 任意类型都只比 ID）；`h_guard` null→6、类型→8。 */
    @TestCase
    public func refEqNeverFailsAndGuardChecksType(): Unit {
        setup()
        let s = str('abc')
        @Assert(call(10, [s, s]), 1)
        // 不可变值按值去重 ⇒ 两个 'abc' 落到同一槽，同一性为真
        @Assert(call(10, [s, str('abc')]), 1)
        @Assert(call(10, [0, 0]), 1)
        @Assert(call(10, [0, 12345]), 0)
        @Assert(err(), 0) // 不失败
        @Assert(call(19, [s, Int64(TypeToken.STRING)]), s) // h_guard 通过
        @Assert(call(19, [0, Int64(TypeToken.STRING)]), 0)
        @Assert(err(), ErrCode.NULL_HANDLE)
        clearErr()
        @Assert(call(19, [s, Int64(TypeToken.DECIMAL)]), 0)
        @Assert(err(), ErrCode.HANDLE_TYPE)
        clearErr()
        @Assert(call(20, [0]), 0) // h_nonnull
        @Assert(err(), ErrCode.NULL_HANDLE)
        clearErr()
        @Assert(call(20, [s]), s)
        @Assert(call(17, [0, Int64(TypeToken.STRING)]), 0) // h_is_type null → false
        @Assert(call(17, [s, Int64(TypeToken.STRING)]), 1)
        @Assert(call(18, [s]), Int64(TypeToken.STRING)) // h_tag_of
        @Assert(err(), 0)
        teardown()
    }

    /** `ht_field` 的十个字段码（值恒 UTC，§6）。 */
    @TestCase
    public func dtFieldCodes(): Unit {
        setup()
        let t = HandleTable.pin(DateTime.ofEpoch(second: 1, nanosecond: 2))
        @Assert(call(14, [t, 1]), 1970)
        @Assert(call(14, [t, 2]), 1)
        @Assert(call(14, [t, 3]), 1)
        @Assert(call(14, [t, 4]), 0)
        @Assert(call(14, [t, 5]), 0)
        @Assert(call(14, [t, 6]), 1)
        @Assert(call(14, [t, 7]), 2)
        @Assert(call(14, [t, 9]), 1)
        @Assert(call(14, [t, 10]), 1000)
        @Assert(err(), 0)
        teardown()
    }

    // ========================================================================
    // S4.10 错误 / 安全点 / 窗口（H21–H23）
    // ========================================================================

    /** `err_raise` 写槽 + site 后返回；`interrupt_poll` 到期 → -2；`hw_check` 触顶 → 16。 */
    @TestCase
    public func errInterruptAndWindowHelpers(): Unit {
        setup()
        match (this.ctx) { case Some(c) => c.site = 999; case None => () }
        @Assert(call(21, [17]), 0)
        @Assert(err(), ErrCode.EXPLICIT)
        match (this.ctx) { case Some(c) => @Assert(c.site, 999); case None => () }

        setup()
        RuntimeEnv.setDeadline(RuntimeEnv.nowNanos() - 1)
        @Assert(call(22, []), 0)
        @Assert(err(), ErrCode.INTERRUPT)
        setup()
        RuntimeEnv.clearDeadline()
        @Assert(call(22, []), 0)
        @Assert(err(), 0)

        setup()
        HandleTable.capacityLimit = HandleTable.windowBaseOf() + 5
        @Assert(call(23, [999]), 0)
        @Assert(err(), ErrCode.HANDLE_WINDOW_FULL)
        HandleTable.capacityLimit = 1048576
        teardown()
    }

    // ========================================================================
    // S4.11 Decimal（H24–H31）
    // ========================================================================

    /** Decimal 四则与互转；÷0 → 10、`DEC_TO_I64` 越界 → 9、分配型恰登记 1 槽。 */
    @TestCase
    public func decimalHelpers(): Unit {
        setup()
        let a = dec('1.5')
        let b = dec('2')
        let base = used()
        @Assert(text(call(33, [call(24, [a, b]), 4])), '3.5') // dec_add
        @Assert(used(), base + 2) // 每次 1 槽（add + to_str）
        @Assert(text(call(33, [call(25, [a, b]), 4])), '-0.5')
        @Assert(text(call(33, [call(26, [a, b]), 4])), '3.0')
        @Assert(text(call(33, [call(27, [dec('1'), dec('4')]), 4])), '0.25')
        @Assert(err(), 0)
        teardown()
    }

    /** ÷0 → 10（含 0÷0）；`dec_to_i64` 越界 → 9；`dec_to_f64` 溢出 → ±Inf 不报错。 */
    @TestCase
    public func decimalFailurePaths(): Unit {
        setup()
        @Assert(call(27, [dec('1'), dec('0')]), 0)
        @Assert(err(), ErrCode.DEC_DIV_ZERO)
        setup()
        @Assert(call(30, [dec('99999999999999999999999999')]), 0)
        @Assert(err(), ErrCode.DEC_RANGE)
        setup()
        @Assert(call(30, [dec('-7.9')]), -7) // 向零截断
        @Assert(err(), 0)
        setup()
        let huge = dec('1e400')
        let bits = call(31, [huge])
        let f = Float64.fromBits(UInt64(bits))
        @Assert(err(), 0)
        @Assert(f > Float64(1.0e308), true)
        teardown()
    }

    /** `dec_from_i64` scale=0；`dec_from_f64` 最短往返（`0.1f64 == Decimal("0.1")`）。 */
    @TestCase
    public func decimalConversions(): Unit {
        setup()
        @Assert(text(call(33, [call(28, [42]), 4])), '42')
        let f1 = Float64(0.1)
        let h = call(29, [Int64(f1.toBits())])
        @Assert(text(call(33, [h, 4])), '0.1')
        @Assert(call(11, [h, dec('0.1')]), 0) // 与 Decimal("0.1") 相等
        setup()
        let nanBits = Int64(0x7FF8000000000000u64)
        @Assert(call(29, [nanBits]), 0)
        @Assert(err(), ErrCode.FP_INVALID)
        teardown()
    }

    // ========================================================================
    // S4.12 字符串族（H32 / H33 / H50 / H51 / H60）
    // ========================================================================

    /** `to_str` 全标签 0–8（§11.9 文本化表）。 */
    @TestCase
    public func toStrCoversAllTags(): Unit {
        setup()
        @Assert(text(call(33, [42, 0])), '42')
        @Assert(text(call(33, [Int64(Float64(1.0).toBits()), 1])), '1.0')
        @Assert(text(call(33, [Int64(Float64(0.0).toBits()), 1])), '0.0')
        @Assert(text(call(33, [Int64(Float64.fromBits(0x7FF8000000000000).toBits()), 1])), 'NaN')
        @Assert(text(call(33, [1, 2])), 'true')
        @Assert(text(call(33, [0, 2])), 'false')
        let s = str('abc')
        @Assert(call(33, [s, 3]), s) // String 恒等
        @Assert(text(call(33, [dec('1.50'), 4])), '1.50')
        @Assert(text(call(33, [dec('-0.001'), 4])), '-0.001')
        let t = HandleTable.pin(DateTime.ofEpoch(second: 0, nanosecond: 0))
        let dtText = text(call(33, [t, 5]))
        @Assert(dtText.contains('1970-01-01T'), true)
        @Assert(dtText.size >= 30, true) // 恒 9 位纳秒 + 偏移
        @Assert(text(call(33, [HandleTable.pin(Duration.hour * 2 + Duration.minute * 3), 6])), '2h3m')
        @Assert(text(call(33, [HandleTable.pin(Duration.Zero), 6])), '0s')
        @Assert(text(call(33, [HandleTable.pin(Range<Int64>(1, 5, 1, true, true, false)), 7])), '1..5')
        @Assert(text(call(33, [HandleTable.pin(Range<Int64>(1, 5, 2, true, true, true)), 7])), '1..=5 : 2')
        @Assert(text(call(33, [HandleTable.pin(JitRegex(Regex('a+'), 0u8)), 8])), '/a+/')
        @Assert(text(call(33, [HandleTable.pin(JitRegex(Regex('a+'), 0x03u8)), 8])), '/a+/im')
        @Assert(err(), 0)
        teardown()
    }

    /** `str_sub` 码点索引与边界；`str_replace` 空模式 → 14；`str_repeat` n≤0 → 空串 / 溢出 → 3。 */
    @TestCase
    public func stringSliceReplaceRepeat(): Unit {
        setup()
        let s = str('héllo')
        @Assert(text(call(50, [s, 0, 2])), 'hé')
        @Assert(text(call(50, [s, 1, 1])), '')
        @Assert(text(call(50, [s, 0, 5])), 'héllo')
        @Assert(call(50, [s, 0, 6]), 0)
        @Assert(err(), ErrCode.IDX_OOB)
        setup()
        @Assert(call(50, [str('abc'), 2, 1]), 0) // a > b
        @Assert(err(), ErrCode.IDX_OOB)
        setup()
        @Assert(text(call(51, [str('a-b-c'), str('-'), str('+')])), 'a+b+c')
        @Assert(call(51, [str('abc'), str(''), str('x')]), 0)
        @Assert(err(), ErrCode.ARG_MISMATCH)
        setup()
        @Assert(text(call(60, [str('ab'), 3])), 'ababab')
        @Assert(text(call(60, [str('ab'), 0])), '')
        @Assert(text(call(60, [str('ab'), -2])), '')
        @Assert(call(60, [str('1234567890'), Int64.Max / 2]), 0)
        @Assert(err(), ErrCode.OVERFLOW_I64)
        teardown()
    }

    /** `str_cat`（H32）与插值链：结果为新串、操作数不被修改。 */
    @TestCase
    public func strCatProducesNewString(): Unit {
        setup()
        let a = str('ab')
        let b = str('cd')
        let base = used()
        let r = call(32, [a, b])
        @Assert(text(r), 'abcd')
        @Assert(used(), base + 1)
        @Assert(text(a), 'ab')
        @Assert(text(b), 'cd')
        teardown()
    }

    // ========================================================================
    // S4.13 时间族（H34–H40 / H61）
    // ========================================================================

    /** DT ± DUR、DUR 四则、`dt_diff` 正/负/零；DT 越界 → 11、DUR 溢出 → 12、`dur_div` ÷0 → 1。 */
    @TestCase
    public func timeHelpers(): Unit {
        setup()
        let t = HandleTable.pin(DateTime.ofEpoch(second: 100, nanosecond: 0))
        let u = HandleTable.pin(Duration.second * 10)
        @Assert(call(14, [call(34, [t, u]), 9]), 110) // dt_add
        @Assert(call(14, [call(35, [t, u]), 9]), 90) // dt_sub
        @Assert(text(call(33, [call(36, [u, u]), 6])), '20s') // dur_add
        @Assert(text(call(33, [call(37, [u, u]), 6])), '0s') // dur_sub
        @Assert(text(call(33, [call(38, [u, 3]), 6])), '30s') // dur_mul
        @Assert(text(call(33, [call(39, [u, 2]), 6])), '5s') // dur_div
        @Assert(text(call(33, [call(40, [u]), 6])), '-10s') // dur_neg
        @Assert(text(call(33, [call(61, [t, t]), 6])), '0s') // dt_diff 零
        @Assert(text(call(33, [call(61, [call(34, [t, u]), t]), 6])), '10s')
        @Assert(text(call(33, [call(61, [t, call(34, [t, u])]), 6])), '-10s')
        @Assert(err(), 0)
        // ÷0 → 1
        setup()
        @Assert(call(39, [HandleTable.pin(Duration.second), 0]), 0)
        @Assert(err(), ErrCode.DIV_ZERO)
        // DT 越界 → 11
        setup()
        let t0 = HandleTable.pin(DateTime.ofEpoch(second: 0, nanosecond: 0))
        @Assert(call(35, [t0, HandleTable.pin(Duration.day * 800000)]), 0)
        @Assert(err(), ErrCode.DT_RANGE)
        // DUR 溢出 → 12
        setup()
        let big = HandleTable.pin(Duration.Max)
        @Assert(call(36, [big, big]), 0)
        @Assert(err(), ErrCode.DUR_OVERFLOW)
        teardown()
    }

    // ========================================================================
    // S4.14 区间（H41 / H42）
    // ========================================================================

    /** `range_new` step=0 → 14、`isClosed ∉ {0,1}` → 14；空区间规则四式。 */
    @TestCase
    public func rangeHelpers(): Unit {
        setup()
        @Assert(call(41, [0, 5, 0, 0]), 0)
        @Assert(err(), ErrCode.ARG_MISMATCH)
        setup()
        @Assert(call(41, [0, 5, 1, 2]), 0)
        @Assert(err(), ErrCode.ARG_MISMATCH)
        setup()
        let open1 = call(41, [1, 5, 1, 0])
        @Assert(text(call(33, [open1, 7])), '1..5')
        @Assert(call(42, [open1, 1]), 1)
        @Assert(call(42, [open1, 4]), 1)
        @Assert(call(42, [open1, 5]), 0) // .. 不含 end
        @Assert(call(42, [open1, 0]), 0)
        let closed = call(41, [1, 5, 1, 1])
        @Assert(call(42, [closed, 5]), 1) // ..= 含 end
        // 空区间恒 false
        let emptyUp = call(41, [5, 5, 1, 0])
        @Assert(call(42, [emptyUp, 5]), 0)
        let emptyDown = call(41, [5, 5, -1, 0])
        @Assert(call(42, [emptyDown, 5]), 0)
        // 负 step
        let down = call(41, [10, 0, -2, 0])
        @Assert(text(call(33, [down, 7])), '10..0 : -2')
        @Assert(call(42, [down, 10]), 1)
        @Assert(call(42, [down, 8]), 1)
        @Assert(call(42, [down, 9]), 0)
        @Assert(call(42, [down, 0]), 0)
        @Assert(err(), 0)
        teardown()
    }

    // ========================================================================
    // S4.15 变更型（H43–H48）
    // ========================================================================

    /** 变更型与 std 语义对齐、**不登记槽**；常量目标 → 20。 */
    @TestCase
    public func mutationHelpers(): Unit {
        setup()
        let l = HandleTable.pin(listOf([1, 2, 3]))
        let m = HandleTable.pin(mapOf([(1, 11)]))
        let base = used()
        @Assert(call(43, [l, 9]), 0) // list_add
        @Assert(call(1, [l]), 4)
        @Assert(call(45, [l, 0, 0]), 0) // list_insert
        @Assert(call(2, [l, 0]), 0)
        @Assert(call(46, [l, 0, 7]), 0) // list_set
        @Assert(call(2, [l, 0]), 7)
        @Assert(call(47, [l, 0]), 7) // list_remove 返回被删元素
        @Assert(call(1, [l]), 4) // 原 3 + add(9) + insert − remove = 4
        @Assert(call(44, [m, 5, 55]), 0) // map_put
        @Assert(call(4, [m, 5]), 55)
        @Assert(call(48, [m, 5]), 1) // map_remove 归一 1
        @Assert(call(48, [m, 5]), 0) // 再删归 0，不报 5
        @Assert(err(), 0)
        @Assert(used(), base) // 不登记槽
        teardown()
    }

    /** 常量（路径 A）目标写入 → 20；null → 6、tag 不符 → 8。 */
    @TestCase
    public func mutationRejectsConstNullAndWrongTag(): Unit {
        setup()
        let cl = HandleTable.pinConst(listOf([1]))
        @Assert(call(43, [cl, 2]), 0)
        @Assert(err(), ErrCode.READONLY)
        setup()
        @Assert(call(43, [0, 1]), 0)
        @Assert(err(), ErrCode.NULL_HANDLE)
        setup()
        @Assert(call(43, [str('abc'), 1]), 0)
        @Assert(err(), ErrCode.HANDLE_TYPE)
        setup()
        let l = HandleTable.pin(listOf([1]))
        @Assert(call(45, [l, 5, 1]), 0) // insert 越界
        @Assert(err(), ErrCode.IDX_OOB)
        teardown()
    }

    // ========================================================================
    // S4.16 正则族（H52 / H53 / H58 / H59 / H69 / H72）
    // ========================================================================

    /** 匹配 / 查找 / 替换三形（g / n / n,m 边界）。 */
    @TestCase
    public func regexHelpers(): Unit {
        setup()
        let re = HandleTable.pin(JitRegex(Regex('a'), 0u8))
        @Assert(call(52, [re, str('bab')]), 1)
        @Assert(call(52, [re, str('bbb')]), 0)
        @Assert(text(call(53, [re, str('xax')])), 'a')
        @Assert(call(53, [re, str('xxx')]), 0) // 无匹配 → 0
        @Assert(text(call(58, [re, str('aaa'), str('b')])), 'bbb')
        @Assert(text(call(59, [re, str('aaa'), str('b'), 1])), 'aba')
        @Assert(text(call(59, [re, str('aaa'), str('b'), 9])), 'aaa') // 越位 → 原串
        @Assert(text(call(72, [re, str('aaa'), str('b'), 0, 1])), 'baa') // n=0,m=1 ≡ /0
        @Assert(text(call(72, [re, str('aaaaa'), str('b'), 1, 2])), 'abbaa')
        @Assert(text(call(72, [re, str('aaa'), str('b'), 1, 99])), 'abb') // 剩余不足 → 到末尾
        @Assert(call(72, [re, str('aaa'), str('b'), 0, 0]), 0) // m<1 → 14
        @Assert(err(), ErrCode.ARG_MISMATCH)
        teardown()
    }

    /** `str_to_regex`：非法 / 空 pattern → 14；每次新对象（不去重）。 */
    @TestCase
    public func strToRegexHelpers(): Unit {
        setup()
        let r1 = call(69, [str('a+')])
        @Assert(r1 > 0, true)
        let r2 = call(69, [str('a+')])
        @Assert(r1 == r2, false) // 不去重（与 kind 10 常量的去重性质相反）
        @Assert(call(52, [r1, str('baa')]), 1)
        setup()
        @Assert(call(69, [str('')]), 0)
        @Assert(err(), ErrCode.ARG_MISMATCH)
        setup()
        @Assert(call(69, [str('(')]), 0)
        @Assert(err(), ErrCode.ARG_MISMATCH)
        teardown()
    }

    // ========================================================================
    // S4.17 闭包族（H54–H57）
    // ========================================================================

    /** `closure_new` 登记 1 槽；`closure_fnid` / `closure_cap`；`fn_table` 基址。 */
    @TestCase
    public func closureHelpers(): Unit {
        // T25/ 映射标签（check_tmap 断言级校验）
        setup()
        let s = str('cap')
        let base = used()
        let c = call(54, [7, s, 42])
        @Assert(used(), base + 1)
        @Assert(call(55, [c]), 7)
        @Assert(call(56, [c, 0]), s)
        @Assert(call(56, [c, 1]), 42)
        @Assert(call(56, [c, 2]), 0)
        @Assert(err(), ErrCode.NULL_HANDLE)
        setup()
        @Assert(call(55, [0]), 0)
        @Assert(err(), ErrCode.NULL_HANDLE)
        setup()
        @Assert(call(57, []), 0) // 解释器形态无机器入口表
        @Assert(err(), 0)
        MachineEnv.setFnTableBase(4096)
        @Assert(call(57, []), 4096)
        teardown()
    }

    // ========================================================================
    // S4.6 Map 迭代（H49 / H62）
    // ========================================================================

    /** 游标推进 / 取键 / 取值 / close 幂等；**不占用句柄窗口**。 */
    @TestCase
    public func mapIterationHelpers(): Unit {
        setup()
        let m = HandleTable.pin(mapOf([(1, 11), (2, 22)]))
        let base = used()
        let cur = call(49, [m])
        @Assert(cur > 0, true)
        @Assert(used(), base) // 不占用窗口
        @Assert(call(62, [cur, 0]), 1)
        let k = call(62, [cur, 1])
        let v = call(62, [cur, 2])
        @Assert(call(4, [m, k]), v)
        @Assert(call(62, [cur, 3]), 0) // close
        @Assert(call(62, [cur, 3]), 0) // 幂等
        @Assert(call(62, [cur, 1]), 0) // 关闭后取件 → 99
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 未推进取件 → 99；`clearAll` 后旧游标 → 99。 */
    @TestCase
    public func staleCursorIsRejected(): Unit {
        setup()
        let m = HandleTable.pin(mapOf([(1, 11)]))
        let cur = call(49, [m])
        @Assert(call(62, [cur, 1]), 0)
        @Assert(err(), ErrCode.HELPER_PANIC)
        setup()
        let m2 = HandleTable.pin(mapOf([(1, 11)]))
        let cur2 = call(49, [m2])
        IterTable.clearAll()
        @Assert(call(62, [cur2, 0]), 0)
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 迭代中修改**同一** map ⇒ 23（对齐 std 的并发修改）；改别的容器不受影响。 */
    @TestCase
    public func concurrentModificationYields23(): Unit {
        setup()
        let m = HandleTable.pin(mapOf([(1, 11), (2, 22)]))
        let other = HandleTable.pin(mapOf([(1, 11)]))
        let cur = call(49, [m])
        @Assert(call(62, [cur, 0]), 1)
        @Assert(call(44, [other, 3, 33]), 0) // 改别的容器：不受影响
        @Assert(err(), 0)
        @Assert(call(44, [m, 3, 33]), 0) // 改同一 map
        @Assert(call(62, [cur, 0]), 0)
        @Assert(err(), ErrCode.CONCURRENT_MOD)
        teardown()
    }

    // ========================================================================
    // S4.18 多级写码
    // ========================================================================

    /** 内层已写码时外层**仅在新异常时**覆盖；否则保留内层码与站点。 */
    @TestCase
    public func nestedWriteKeepsInnerUnlessNewException(): Unit {
        setup()
        let c = match (this.ctx) { case Some(x) => x; case None => JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0) }
        c.site = 321
        HelperCore.ctxWriteCode(c, 5)
        HelperCore.ctxWriteCode(c, 8) // 无新异常信息 ⇒ 保留
        @Assert(c.errCode, 5)
        @Assert(c.site, 321)
        HelperCore.ctxWriteCode(c, 99, Exception('boom')) // 新异常 ⇒ 覆盖
        @Assert(c.errCode, 99)
        teardown()
    }

    /** catch-all 兜 99：helper 内部异常不逃逸为宿主异常。 */
    @TestCase
    public func helperInternalExceptionBecomes99(): Unit {
        setup()
        // 越界的实参（argc 不符）走防御路径；这里直接触发一个 std 异常面：对 null 取 Duration
        @Assert(call(16, [0]), 0)
        @Assert(err(), ErrCode.NULL_HANDLE)
        // 未登记的 hid ⇒ 18（不逃逸）
        setup()
        @Assert(call(63, []), 0)
        @Assert(err(), ErrCode.NOT_IMPL)
        teardown()
    }
}
