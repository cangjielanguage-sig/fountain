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

import std.collection.ArrayList
import std.collection.HashMap
import std.convert.*
import std.math.numeric.BigInt
import std.math.numeric.Decimal
import std.math.numeric.OverflowStrategy
import std.regex.Regex
import std.time.DateTime
import fountain::f_base.*
import fountain::f_regex.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * H01–H72 的仓颉实现（**三引擎共用同一份** —— design D4）与 hid 分派。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §6 的 helper 表（签名、失败码、分配型 / 变更型归属）。
 * 每个 helper 的形状都是「取值 → 校验 → 调 std → 返回 cell」；失败一律 `failWith(code)`，
 * 由 `invokeHelper` 的 `catch` 转码写槽，**绝不把异常抛给字节码或机器码**（design D5）。
 */

/** hid → 实现（§6 表）。 */
internal func dispatchHelper(ctx: JitContext, hid: Int64, a: Array<Int64>): Int64 {
    match (hid) {
        // ---- 容器 / 字符串读（H01–H08）----
        case 1 => hlLen(ctx, a)
        case 2 => hlGet(ctx, a)
        case 3 => hmLen(ctx, a)
        case 4 => hmGet(ctx, a)
        case 5 => hmGetOr(ctx, a)
        case 6 => hmHas(ctx, a)
        case 7 => hsLen(ctx, a)
        case 8 => hsAt(ctx, a)
        // ---- 比较 / 判定（H09–H20）----
        case 9 => hsCmp(ctx, a)
        case 10 => hRefEq(ctx, a)
        case 11 => hdCmp(ctx, a)
        case 12 => hdIsInt(ctx, a)
        case 13 => htCmp(ctx, a)
        case 14 => htField(ctx, a)
        case 15 => hdurCmp(ctx, a)
        case 16 => hdurTicks(ctx, a)
        case 17 => hIsType(ctx, a)
        case 18 => hTagOf(ctx, a)
        case 19 => hGuard(ctx, a)
        case 20 => hNonnull(ctx, a)
        // ---- 错误 / 安全点 / 窗口（H21–H23）----
        case 21 => errRaise(ctx, a)
        case 22 => interruptPoll(ctx, a)
        case 23 => hwCheck(ctx, a)
        // ---- Decimal（H24–H31）----
        case 24 => decBin(ctx, a, 0)
        case 25 => decBin(ctx, a, 1)
        case 26 => decBin(ctx, a, 2)
        case 27 => decBin(ctx, a, 3)
        case 28 => decFromI64(ctx, a)
        case 29 => decFromF64(ctx, a)
        case 30 => decToI64(ctx, a)
        case 31 => decToF64(ctx, a)
        // ---- 字符串 / 文本化（H32 / H33 / H50 / H51 / H60）----
        case 32 => strCat(ctx, a)
        case 33 => toStr(ctx, a)
        case 50 => strSub(ctx, a)
        case 51 => strReplace(ctx, a)
        case 60 => strRepeat(ctx, a)
        // ---- 时间（H34–H40 / H61）----
        case 34 => dtArith(ctx, a, true)
        case 35 => dtArith(ctx, a, false)
        case 36 => durArith(ctx, a, 0)
        case 37 => durArith(ctx, a, 1)
        case 38 => durMul(ctx, a)
        case 39 => durDiv(ctx, a)
        case 40 => durNeg(ctx, a)
        case 61 => dtDiff(ctx, a)
        // ---- 时间构造（M1 扩展 H73–H76）----
        case 73 => dtNow(ctx, a)
        case 74 => dtParse(ctx, a)
        case 75 => dtOf(ctx, a)
        case 76 => durParse(ctx, a)
        // ---- 区间（H41 / H42）----
        case 41 => rangeNew(ctx, a)
        case 42 => rangeContains(ctx, a)
        // ---- 变更型（H43–H48）----
        case 43 => listAdd(ctx, a)
        case 44 => mapPut(ctx, a)
        case 45 => listInsert(ctx, a)
        case 46 => listSet(ctx, a)
        case 47 => listRemove(ctx, a)
        case 48 => mapRemove(ctx, a)
        // ---- Map 迭代（H49 / H62）----
        case 49 => mapIterBegin(ctx, a)
        case 62 => mapIterStep(ctx, a)
        // ---- 正则（H52 / H53 / H58 / H59 / H69 / H72）----
        case 52 => regexIsMatch(ctx, a)
        case 53 => regexFind(ctx, a)
        case 58 => regexReplaceAll(ctx, a)
        case 59 => regexReplaceNth(ctx, a)
        case 69 => strToRegex(ctx, a)
        case 72 => regexReplaceRange(ctx, a)
        // ---- 闭包（H54–H57）----
        case 54 => closureNew(ctx, a)
        case 55 => closureFnid(ctx, a)
        case 56 => closureCap(ctx, a)
        case 57 => fnTable(ctx, a)
        // ---- 空容器构造（H70 / H71）----
        case 70 => listNew(ctx, a)
        case 71 => mapNew(ctx, a)
        case _ => failWith(ErrCode.NOT_IMPL)
    }
}

// ============================================================================
// H01–H08 容器 / 字符串读（不登记槽）
// ============================================================================

internal func hlLen(ctx: JitContext, a: Array<Int64>): Int64 {
    let l = HandleTable.fetchList(argAt(a, 0))
    Int64(l.size)
}

internal func hlGet(ctx: JitContext, a: Array<Int64>): Int64 {
    let l = HandleTable.fetchList(argAt(a, 0))
    let i = argAt(a, 1)
    if (i < 0 || i >= Int64(l.size)) {
        failWith(ErrCode.IDX_OOB)
    }
    HandleTable.anyToCell(l[Int64(i)])
}

internal func hmLen(ctx: JitContext, a: Array<Int64>): Int64 {
    let m = HandleTable.fetchMap(argAt(a, 0))
    Int64(m.size)
}

internal func hmGet(ctx: JitContext, a: Array<Int64>): Int64 {
    let m = HandleTable.fetchMap(argAt(a, 0))
    let k = mapKeyOf(argAt(a, 1))
    match (m.get(k)) {
        case Some(v) => HandleTable.anyToCell(v)
        case None => failWith(ErrCode.KEY_MISSING)
    }
}

internal func hmGetOr(ctx: JitContext, a: Array<Int64>): Int64 {
    let m = HandleTable.fetchMap(argAt(a, 0))
    let k = mapKeyOf(argAt(a, 1))
    match (m.get(k)) {
        case Some(v) => HandleTable.anyToCell(v)
        case None => argAt(a, 2)
    }
}

internal func hmHas(ctx: JitContext, a: Array<Int64>): Int64 {
    let m = HandleTable.fetchMap(argAt(a, 0))
    let k = mapKeyOf(argAt(a, 1))
    if (m.contains(k)) { 1 } else { 0 }
}

/** String 长度按**码点**计（与 `STR_AT` / `STR_SUB` 同一索引域，§11.4）。 */
internal func hsLen(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    Int64(s.toRuneArray().size)
}

internal func hsAt(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    let i = argAt(a, 1)
    let rs = s.toRuneArray()
    if (i < 0 || i >= Int64(rs.size)) {
        failWith(ErrCode.IDX_OOB)
    }
    Int64(UInt32(rs[Int64(i)]))
}

// ============================================================================
// H09–H20 比较 / 判定
// ============================================================================

internal func hsCmp(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchString(argAt(a, 0))
    let y = HandleTable.fetchString(argAt(a, 1))
    orderingCell(x.compare(y))
}

internal func hRefEq(ctx: JitContext, a: Array<Int64>): Int64 {
    // 同一性比较：**恒不失败**（不解引用、不校验类型）
    if (argAt(a, 0) == argAt(a, 1)) { 1 } else { 0 }
}

internal func hdCmp(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchDecimal(argAt(a, 0))
    let y = HandleTable.fetchDecimal(argAt(a, 1))
    orderingCell(x.compare(y))
}

internal func hdIsInt(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDecimal(argAt(a, 0))
    if (d.isInteger()) { 1 } else { 0 }
}

internal func htCmp(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchDateTime(argAt(a, 0))
    let y = HandleTable.fetchDateTime(argAt(a, 1))
    orderingCell(x.compare(y))
}

/** `ht_field` 的 f：1=year 2=month 3=day 4=hour 5=minute 6=second 7=nanosecond
 *  8=dayOfWeek 9=epochSec 10=epochMilli（§6；值恒 UTC，§11.4）。 */
internal func htField(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDateTime(argAt(a, 0))
    let f = argAt(a, 1)
    match (f) {
        case 1 => d.year
        case 2 => d.month.toInteger()
        case 3 => d.dayOfMonth
        case 4 => d.hour
        case 5 => d.minute
        case 6 => d.second
        case 7 => d.nanosecond
        case 8 => d.dayOfWeek.toInteger()
        case 9 => d.toUnixTimeStamp().toSeconds()
        case 10 => d.toUnixTimeStamp().toMilliseconds()
        case _ => failWith(ErrCode.DT_RANGE)
    }
}

internal func hdurCmp(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchDuration(argAt(a, 0))
    let y = HandleTable.fetchDuration(argAt(a, 1))
    orderingCell(x.compare(y))
}

internal func hdurTicks(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDuration(argAt(a, 0))
    try {
        d.toNanoseconds()
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
}

internal func hIsType(ctx: JitContext, a: Array<Int64>): Int64 {
    let tok = UInt16(argAt(a, 1))
    if (HandleTable.isType(argAt(a, 0), tok)) { 1 } else { 0 }
}

internal func hTagOf(ctx: JitContext, a: Array<Int64>): Int64 {
    Int64(HandleTable.tagOfHandle(argAt(a, 0)))
}

internal func hGuard(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let tok = UInt16(argAt(a, 1))
    if (!HandleTable.isType(h, tok)) {
        if (h == 0) {
            failWith(ErrCode.NULL_HANDLE)
        }
        failWith(ErrCode.HANDLE_TYPE)
    }
    h
}

internal func hNonnull(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    if (h == 0) {
        failWith(ErrCode.NULL_HANDLE)
    }
    h
}

internal func orderingCell(o: Ordering): Int64 {
    match (o) {
        case Ordering.LT => -1
        case Ordering.EQ => 0
        case Ordering.GT => 1
        case _ => 0
    }
}

// ============================================================================
// H21–H23 错误 / 安全点 / 窗口
// ============================================================================

/** `err_raise(code)`：写错误槽（site 由 `SET_SITE` 已置）后返回 0。 */
internal func errRaise(ctx: JitContext, a: Array<Int64>): Int64 {
    HelperCore.ctxWriteCode(ctx, argAt(a, 0))
    0
}

/** `interrupt_poll`：`deadline` 到期 ⇒ -2（`ErrCode.INTERRUPT`）。 */
internal func interruptPoll(ctx: JitContext, a: Array<Int64>): Int64 {
    if (RuntimeEnv.deadlineExpired()) {
        HelperCore.ctxWriteCode(ctx, ErrCode.INTERRUPT)
    }
    0
}

/**
 * `hw_check(cap)`：再追加 `cap` 个槽会越出全局上限 ⇒ 16（§9 附则 6 的**防御**入口，
 * 真正常规路径由 `HandleTable.append` 的倍增扩容兜住）。
 */
internal func hwCheck(ctx: JitContext, a: Array<Int64>): Int64 {
    let cap = argAt(a, 0)
    let used = HandleTable.windowUsed()
    let limit = HandleTable.capacityLimit - HandleTable.windowBaseOf()
    if (used + cap > limit) {
        failWith(ErrCode.HANDLE_WINDOW_FULL)
    }
    0
}

// ============================================================================
// H24–H31 Decimal（std 默认上下文，§9 附则 12）
// ============================================================================

internal func decBin(ctx: JitContext, a: Array<Int64>, op: Int64): Int64 {
    let x = HandleTable.fetchDecimal(argAt(a, 0))
    let y = HandleTable.fetchDecimal(argAt(a, 1))
    var r = Decimal(0)
    try {
        match (op) {
            case 0 => r = x + y
            case 1 => r = x - y
            case 2 => r = x * y
            case _ => r = x / y
        }
    } catch (e: Exception) {
        // 除零（含 0÷0）⇒ 10；其余按 std 语义转 9
        if (op == 3 && y == Decimal(0)) {
            failWith(ErrCode.DEC_DIV_ZERO)
        }
        failWith(ErrCode.DEC_RANGE)
    }
    allocValue(ctx, r)
}

internal func decFromI64(ctx: JitContext, a: Array<Int64>): Int64 {
    allocValue(ctx, Decimal(argAt(a, 0)))
}

/** `dec_from_f64`：最短往返十进制表示（§11.9）；NaN / ±Inf ⇒ 13。 */
internal func decFromF64(ctx: JitContext, a: Array<Int64>): Int64 {
    let bits = UInt64(argAt(a, 0))
    let v = Float64.fromBits(bits)
    let exp = Int64((bits >> 52) & 0x7FFu64)
    if (exp == 0x7FF) {
        failWith(ErrCode.FP_INVALID)
    }
    let r = TextFormat.shortestDigits(exp, bits & 0x000FFFFFFFFFFFFFu64)
    let d = decFromTriple(if (argAt(a, 0) < 0) { 1u8 } else { 0u8 }, Int32(r[2]), r[1])
    allocValue(ctx, d)
}

/** `dec_to_i64`：向零截断；越界 ⇒ 9（mode=1 由指令层转 DEOPT，helper 只管报错模式）。 */
internal func decToI64(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDecimal(argAt(a, 0))
    try {
        d.toInt64(overflowHandling: OverflowStrategy.Throwing)
    } catch (e: Exception) {
        failWith(ErrCode.DEC_RANGE)
    }
}

/** `dec_to_f64`：IEEE 最近偶数；溢出 ⇒ ±Inf（**不报错**）。 */
internal func decToF64(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDecimal(argAt(a, 0))
    Int64(d.toFloat64().toBits())
}

// ============================================================================
// H32 / H33 / H50 / H51 / H60 字符串与文本化
// ============================================================================

internal func strCat(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchString(argAt(a, 0))
    let y = HandleTable.fetchString(argAt(a, 1))
    allocValue(ctx, x + y)
}

/**
 * `to_str(v, t)`：t = 0=I64 1=F64 2=Bool 3=String 4=Decimal 5=DateTime 6=Duration
 * 7=Range 8=Regex（§6）。
 *
 * String 是**恒等**（§11.9「原样（插值语义，不加引号）」⇒ 不新登记槽）；其余标签登记 1 槽。
 */
internal func toStr(ctx: JitContext, a: Array<Int64>): Int64 {
    let v = argAt(a, 0)
    let t = argAt(a, 1)
    match (t) {
        case 0 => allocValue(ctx, TextFormat.i64(v))
        case 1 => allocValue(ctx, TextFormat.f64(Float64.fromBits(UInt64(v))))
        case 2 => allocValue(ctx, TextFormat.bool(v != 0))
        case 3 =>
            // String 恒等：回原句柄（null ⇒ 6，由 fetch 的类型/空校验给出）
            HandleTable.fetchString(v)
            v
        case 4 => allocValue(ctx, TextFormat.decimal(HandleTable.fetchDecimal(v)))
        case 5 => allocValue(ctx, TextFormat.dateTime(HandleTable.fetchDateTime(v)))
        case 6 => allocValue(ctx, TextFormat.duration(HandleTable.fetchDuration(v)))
        case 7 => allocValue(ctx, TextFormat.range(HandleTable.fetchRange(v)))
        case 8 => allocValue(ctx, TextFormat.regex(HandleTable.fetchRegexEx(v)))
        case _ => failWith(ErrCode.ARG_MISMATCH)
    }
}

/** `str_sub(h, a, b)`：**码点**索引半开区间 `[a, b)`（§5 / §11.4）。 */
internal func strSub(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    let x = argAt(a, 1)
    let y = argAt(a, 2)
    let rs = s.toRuneArray()
    let n = Int64(rs.size)
    if (x < 0 || y > n || x > y) {
        failWith(ErrCode.IDX_OOB)
    }
    var out = ArrayList<Rune>()
    var i = x
    while (i < y) {
        out.add(rs[Int64(i)])
        i = i + 1
    }
    allocValue(ctx, String(out.toArray()))
}

/** `str_replace(h, old, new)`：全部子串替换；old 为空串 ⇒ 14。 */
internal func strReplace(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    let oldS = HandleTable.fetchString(argAt(a, 1))
    let newS = HandleTable.fetchString(argAt(a, 2))
    if (oldS.isEmpty()) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, s.replace(oldS, newS))
}

/**
 * `str_repeat(h, n)`：`n ≤ 0` ⇒ 空串；`n × len_utf8` 以 Int64 计算溢出 ⇒ 3（§11.9 v0.15）。
 */
internal func strRepeat(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    let n = argAt(a, 1)
    if (n <= 0) {
        return allocValue(ctx, '')
    }
    let len = Int64(s.size)
    if (len > 0 && n > Int64.Max / len) {
        failWith(ErrCode.OVERFLOW_I64)
    }
    var piece = s
    var left = n
    var out = ''
    while (left > 0) {
        if ((left & 1) == 1) {
            out = out + piece
        }
        left = left >> 1
        if (left > 0) {
            piece = piece + piece
        }
    }
    allocValue(ctx, out)
}

// ============================================================================
// H34–H40 / H61 时间（值恒 UTC，§11.4）
// ============================================================================

internal func dtArith(ctx: JitContext, a: Array<Int64>, isAdd: Bool): Int64 {
    let d = HandleTable.fetchDateTime(argAt(a, 0))
    let u = HandleTable.fetchDuration(argAt(a, 1))
    var r = d
    try {
        r = if (isAdd) { d + u } else { d - u }
    } catch (e: Exception) {
        failWith(ErrCode.DT_RANGE)
    }
    if (r.year < 1 || r.year > 9999) {
        failWith(ErrCode.DT_RANGE)
    }
    allocValue(ctx, r)
}

internal func durArith(ctx: JitContext, a: Array<Int64>, op: Int64): Int64 {
    let x = HandleTable.fetchDuration(argAt(a, 0))
    let y = HandleTable.fetchDuration(argAt(a, 1))
    var r = x
    try {
        r = if (op == 0) { x + y } else { x - y }
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
    allocValue(ctx, r)
}

internal func durMul(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDuration(argAt(a, 0))
    let k = argAt(a, 1)
    var r = d
    try {
        r = d * k
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
    allocValue(ctx, r)
}

/** `dur_div(d, n)`：`n = 0` ⇒ 1（§6）。 */
internal func durDiv(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDuration(argAt(a, 0))
    let k = argAt(a, 1)
    if (k == 0) {
        failWith(ErrCode.DIV_ZERO)
    }
    var r = d
    try {
        r = d / k
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
    allocValue(ctx, r)
}

internal func durNeg(ctx: JitContext, a: Array<Int64>): Int64 {
    let d = HandleTable.fetchDuration(argAt(a, 0))
    var r = d
    try {
        r = Duration.Zero - d
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
    allocValue(ctx, r)
}

/** `dt_diff(dt1, dt2)` → Duration（可为负）；超出 Duration 值域 ⇒ 12。 */
internal func dtDiff(ctx: JitContext, a: Array<Int64>): Int64 {
    let x = HandleTable.fetchDateTime(argAt(a, 0))
    let y = HandleTable.fetchDateTime(argAt(a, 1))
    var r = Duration.Zero
    try {
        r = x - y
    } catch (e: Exception) {
        failWith(ErrCode.DUR_OVERFLOW)
    }
    allocValue(ctx, r)
}

// ============================================================================
// H73–H76 时间 / 间隔构造（M1 扩展：源语言 DateTime.* / Duration.parse）
// ============================================================================

/** `datetime_now()`：宿主当前时间（`DateTime.now()`，本地时区）。 */
internal func dtNow(ctx: JitContext, a: Array<Int64>): Int64 {
    allocValue(ctx, DateTime.now())
}

/** `datetime_parse(s)`：RFC3339 date-time；非法 → 14。 */
internal func dtParse(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    var dt = DateTime.now()
    try {
        dt = DateTime.parse(s)
    } catch (_: Exception) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, dt)
}

/** `datetime_of(y, m, d[, h, mi, s[, ns]])`：位置参数 3–7 个；非法日期 → 14。 */
internal func dtOf(ctx: JitContext, a: Array<Int64>): Int64 {
    let n = a.size
    if (n < 3 || n > 7) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    let y = argAt(a, 0)
    let mo = argAt(a, 1)
    let d = argAt(a, 2)
    let h = if (n > 3) { argAt(a, 3) } else { 0 }
    let mi = if (n > 4) { argAt(a, 4) } else { 0 }
    let se = if (n > 5) { argAt(a, 5) } else { 0 }
    let ns = if (n > 6) { argAt(a, 6) } else { 0 }
    var dt = DateTime.now()
    try {
        dt = DateTime.of(year: y, month: mo, dayOfMonth: d, hour: h, minute: mi, second: se,
            nanosecond: ns)
    } catch (_: Exception) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, dt)
}

/** `duration_parse(s)`：与 `fountain::f_data` 的 `Duration.parse` 同形；非法 → 14。 */
internal func durParse(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    allocValue(ctx, parseDurationText(s))
}

/**
 * Duration 文本解析（与 `f_data/src/base/DataParsable.cj` 同语义）：
 * 可选整串符号 + 严格递减单位的「整数+单位」串（`1h2m3s`、`-1m2s`）；
 * 单位至多一次、段间不允许符号与空白；非法或溢出 → 14。
 */
private func parseDurationText(value: String): Duration {
    if (value.isEmpty()) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    var duration = Duration.Zero
    var i = 0
    var parsed = false
    var negative = false
    var lastRank = -1
    try {
        while (i < value.size) {
            let start = i
            if (value[i] == b'-' || value[i] == b'+') {
                if (start != 0) {
                    failWith(ErrCode.ARG_MISMATCH)
                }
                negative = value[i] == b'-'
                i = i + 1
            }
            let digits = i
            while (i < value.size && value[i] >= b'0' && value[i] <= b'9') {
                i = i + 1
            }
            if (i == digits || i == value.size) {
                failWith(ErrCode.ARG_MISMATCH)
            }
            let numberStart = if (value[start] == b'+') { start + 1 } else { start }
            let number = match (Int64.tryParse(value[numberStart..i])) {
                case Some(n) => n
                case None => failWith(ErrCode.ARG_MISMATCH)
            }
            let unit = value[i]
            i = i + 1
            let (scale, rank) = match (unit) {
                case b'd' => (Duration.day, 0)
                case b'h' => (Duration.hour, 1)
                case b'm' =>
                    if (i < value.size && value[i] == b's') {
                        i = i + 1
                        (Duration.millisecond, 4)
                    } else {
                        (Duration.minute, 2)
                    }
                case b's' => (Duration.second, 3)
                case b'u' =>
                    if (i >= value.size || value[i] != b's') {
                        failWith(ErrCode.ARG_MISMATCH)
                    }
                    i = i + 1
                    (Duration.microsecond, 5)
                case b'n' =>
                    if (i >= value.size || value[i] != b's') {
                        failWith(ErrCode.ARG_MISMATCH)
                    }
                    i = i + 1
                    (Duration.nanosecond, 6)
                case _ => failWith(ErrCode.ARG_MISMATCH)
            }
            if (rank <= lastRank) {
                failWith(ErrCode.ARG_MISMATCH)
            }
            lastRank = rank
            if (parsed && negative) {
                duration = duration + scale * (-number)
            } else {
                duration = duration + scale * number
            }
            parsed = true
        }
    } catch (_: ArithmeticException) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    if (!parsed) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    duration
}

// ============================================================================
// H41 / H42 区间（严格对齐仓颉 `Range<Int64>`，§11.9）
// ============================================================================

/** `range_new(start, end, step, isClosed)`：`step = 0` 或 `isClosed ∉ {0,1}` ⇒ 14。 */
internal func rangeNew(ctx: JitContext, a: Array<Int64>): Int64 {
    let start = argAt(a, 0)
    let end = argAt(a, 1)
    let step = argAt(a, 2)
    let closed = argAt(a, 3)
    if (step == 0 || (closed != 0 && closed != 1)) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, Range<Int64>(start, end, step, true, true, closed != 0))
}

/** `range_contains(h, v)`：空区间恒 false；`..=` 含 end（§11.9 四式）。 */
internal func rangeContains(ctx: JitContext, a: Array<Int64>): Int64 {
    let r = HandleTable.fetchRange(argAt(a, 0))
    let v = argAt(a, 1)
    let closed = r.isClosed
    let up = r.step > 0
    var ok = false
    if (up) {
        if (v < r.start) {
            ok = false
        } else if (closed) {
            ok = v <= r.end
        } else {
            ok = v < r.end
        }
    } else {
        if (v > r.start) {
            ok = false
        } else if (closed) {
            ok = v >= r.end
        } else {
            ok = v > r.end
        }
    }
    if (!ok) {
        return 0
    }
    // 对齐仓颉：按 step 步进可达才算「包含」
    let d = if (up) { v - r.start } else { r.start - v }
    if (d % (if (r.step > 0) { r.step } else { 0 - r.step }) == 0) { 1 } else { 0 }
}

// ============================================================================
// H43–H48 变更型（**不登记槽**；常量目标 ⇒ 20，§9 附则 15①）
// ============================================================================

internal func checkMutable(h: Int64): Unit {
    if (HandleTable.isConst(h)) {
        failWith(ErrCode.READONLY)
    }
}

internal func listAdd(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let l = HandleTable.fetchList(h)
    checkMutable(h)
    l.add(HandleTable.cellToAny(argAt(a, 1)))
    0
}

internal func mapPut(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let m = HandleTable.fetchMap(h)
    checkMutable(h)
    let kc = argAt(a, 1)
    let k = mapKeyOf(kc)
    m.add(k, HandleTable.cellToAny(argAt(a, 2)))
    0
}

internal func listInsert(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let l = HandleTable.fetchList(h)
    checkMutable(h)
    let i = argAt(a, 1)
    if (i < 0 || i > Int64(l.size)) {
        failWith(ErrCode.IDX_OOB)
    }
    l.add(HandleTable.cellToAny(argAt(a, 2)), at: Int64(i))
    0
}

internal func listSet(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let l = HandleTable.fetchList(h)
    checkMutable(h)
    let i = argAt(a, 1)
    if (i < 0 || i >= Int64(l.size)) {
        failWith(ErrCode.IDX_OOB)
    }
    l[Int64(i)] = HandleTable.cellToAny(argAt(a, 2))
    0
}

/** `list_remove(h, i)`：返回**被删元素**（§6）。 */
internal func listRemove(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let l = HandleTable.fetchList(h)
    checkMutable(h)
    let i = argAt(a, 1)
    if (i < 0 || i >= Int64(l.size)) {
        failWith(ErrCode.IDX_OOB)
    }
    HandleTable.anyToCell(l.remove(at: Int64(i)))
}

/** `map_remove(h, k)`：归一为 0/1（1 = 已删，0 = 本无此键，**不报 5**）。 */
internal func mapRemove(ctx: JitContext, a: Array<Int64>): Int64 {
    let h = argAt(a, 0)
    let m = HandleTable.fetchMap(h)
    checkMutable(h)
    let k = mapKeyOf(argAt(a, 1))
    match (m.remove(k)) {
        case Some(_) => 1
        case None => 0
    }
}

// ============================================================================
// H49 / H62 Map 迭代（不登记槽；迭代中改同一 map ⇒ 23）
// ============================================================================

internal func mapIterBegin(ctx: JitContext, a: Array<Int64>): Int64 {
    IterTable.open(argAt(a, 0), 0u8)
}

/** mode 0=推进、1=键、2=值、3=close（§5 / §11.9）。 */
internal func mapIterStep(ctx: JitContext, a: Array<Int64>): Int64 {
    let cur = argAt(a, 0)
    let mode = argAt(a, 1)
    match (mode) {
        case 0 => if (IterTable.next(cur)) { 1 } else { 0 }
        case 1 => IterTable.key(cur)
        case 2 => IterTable.value(cur)
        case 3 => IterTable.close(cur); 0
        case _ => failWith(ErrCode.HELPER_PANIC)
    }
}

// ============================================================================
// H52 / H53 / H58 / H59 / H69 / H72 正则
// ============================================================================

internal func regexIsMatch(ctx: JitContext, a: Array<Int64>): Int64 {
    let re = HandleTable.fetchRegexEx(argAt(a, 0))
    let s = HandleTable.fetchString(argAt(a, 1))
    if (re.re.matches(s)) { 1 } else { 0 }
}

/** `regex_find`：首个匹配（group-0）的新 String；无匹配 ⇒ 0（§5）。 */
internal func regexFind(ctx: JitContext, a: Array<Int64>): Int64 {
    let re = HandleTable.fetchRegexEx(argAt(a, 0))
    let s = HandleTable.fetchString(argAt(a, 1))
    match (re.re.find(s)) {
        case Some(md) => allocValue(ctx, md.matchString())
        case None => 0
    }
}

internal func regexReplaceAll(ctx: JitContext, a: Array<Int64>): Int64 {
    let re = HandleTable.fetchRegexEx(argAt(a, 0))
    let s = HandleTable.fetchString(argAt(a, 1))
    let r = HandleTable.fetchString(argAt(a, 2))
    allocValue(ctx, replaceSpans(re.re, s, r, 0, -1))
}

/** `regex_replace_nth(re, s, r, n)`：只替换第 n 个（从 0 计）；越位 ⇒ 原串（不报错）。 */
internal func regexReplaceNth(ctx: JitContext, a: Array<Int64>): Int64 {
    let re = HandleTable.fetchRegexEx(argAt(a, 0))
    let s = HandleTable.fetchString(argAt(a, 1))
    let r = HandleTable.fetchString(argAt(a, 2))
    let n = argAt(a, 3)
    if (n < 0) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, replaceSpans(re.re, s, r, n, 1))
}

/**
 * `regex_replace_range(re, s, r, n, m)`：替换序号 ∈ `[n, n+m)` 的匹配；剩余不足 m ⇒ 替换到
 * 末尾（不报错）；`n < 0` 或 `m < 1` ⇒ 14（v0.18.19 / v0.18.20）。
 */
internal func regexReplaceRange(ctx: JitContext, a: Array<Int64>): Int64 {
    let re = HandleTable.fetchRegexEx(argAt(a, 0))
    let s = HandleTable.fetchString(argAt(a, 1))
    let r = HandleTable.fetchString(argAt(a, 2))
    let n = argAt(a, 3)
    let m = argAt(a, 4)
    if (n < 0 || m < 1) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, replaceSpans(re.re, s, r, n, m))
}

/** `str_to_regex`：运行期由字符串构造（恒无 flags）；非法 / 空 pattern ⇒ 14（v0.17）。 */
internal func strToRegex(ctx: JitContext, a: Array<Int64>): Int64 {
    let s = HandleTable.fetchString(argAt(a, 0))
    if (s.isEmpty()) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    var re = Regex('a')
    try {
        re = s.regex()
    } catch (e: Exception) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    allocValue(ctx, JitRegex(re, 0u8))
}

/**
 * 按匹配区间做**字面文本**替换（`count < 0` = 全部）。
 *
 * 各匹配位置取自 std 的 `lazyFindAll`（其 `Position` 是**字节**偏移，与 §11.4 的字符串索引
 * 约定一致）；序号落在 `[from, from+count)` 的匹配换为 replacement，其余原样。
 */
internal func replaceSpans(re: Regex, input: String, repl: String, from: Int64, count: Int64): String {
    let bs = input.unsafeBytes()
    var starts = ArrayList<Int64>()
    var ends = ArrayList<Int64>()
    for (md in re.lazyFindAll(input)) {
        let p = md.matchPosition()
        starts.add(p.start)
        ends.add(p.end)
    }
    let total = starts.size
    if (total == 0) {
        return input
    }
    let rbs = repl.unsafeBytes()
    var out = ArrayList<UInt8>()
    var cur: Int64 = 0
    var i: Int64 = 0
    while (i < total) {
        let s = starts[i]
        let e = ends[i]
        var k = cur
        while (k < s) {
            out.add(bs[k])
            k = k + 1
        }
        let inRange = i >= from && (count < 0 || i < from + count)
        if (inRange) {
            for (b in rbs) {
                out.add(b)
            }
        } else {
            var k2 = s
            while (k2 < e) {
                out.add(bs[k2])
                k2 = k2 + 1
            }
        }
        cur = e
        i = i + 1
    }
    var k3 = cur
    while (k3 < bs.size) {
        out.add(bs[k3])
        k3 = k3 + 1
    }
    String.fromUtf8(out.toArray())
}

// ============================================================================
// H54–H57 闭包（§8.6）
// ============================================================================

/** `closure_new(fnId, cap…)`：闭包对象 = `{fnId, 捕获快照}`；登记 1 槽。 */
internal func closureNew(ctx: JitContext, a: Array<Int64>): Int64 {
    let fnId = argAt(a, 0)
    let n = a.size - 1
    var caps = ArrayList<Int64>()
    var i = 1
    while (i <= n) {
        caps.add(a[i])
        i = i + 1
    }
    allocValue(ctx, JitClosure(fnId, caps.toArray()))
}

internal func closureFnid(ctx: JitContext, a: Array<Int64>): Int64 {
    HandleTable.fetchClosure(argAt(a, 0)).fnId
}

/** `closure_cap(h, i)`：取第 i 个捕获 cell；越界 ⇒ 6（§6「6, 8」）。 */
internal func closureCap(ctx: JitContext, a: Array<Int64>): Int64 {
    let c = HandleTable.fetchClosure(argAt(a, 0))
    let i = argAt(a, 1)
    if (i < 0 || i >= Int64(c.captured.size)) {
        failWith(ErrCode.NULL_HANDLE)
    }
    c.captured[Int64(i)]
}

/**
 * `fn_table`：机器入口表基址。
 *
 * 解释器形态**没有**机器码入口表 ⇒ 返回 0（null）；只有 JIT 产物经 backend 写入非 GC 内存后
 * 才有基址（§5.3.4「fn_table 返回机器入口表基址」）。
 */
internal func fnTable(ctx: JitContext, a: Array<Int64>): Int64 {
    MachineEnv.fnTableBase
}

// ============================================================================
// H70 / H71 空容器构造（v0.18；分配型、可变、不进常量表）
// ============================================================================

internal func listNew(ctx: JitContext, a: Array<Int64>): Int64 {
    allocValue(ctx, makeRuntimeList())
}

internal func mapNew(ctx: JitContext, a: Array<Int64>): Int64 {
    allocValue(ctx, makeRuntimeMap())
}
