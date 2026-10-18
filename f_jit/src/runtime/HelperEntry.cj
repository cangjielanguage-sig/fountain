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

/**
 * H01–H72 的 `@C` 薄入口（design-m1 §5.3.4、§6）。
 *
 * 机器码经固定 ABI 调用本表：`rdi = ctx`、`rsi = &args[0]`、`rdx = nargs`、`ret rax = cell`。
 * 每个入口只做三件事——构造访问器、把实参抄进托管数组、委托给 `invokeHelper`（**三引擎共用的
 * 同一份仓颉实现**）；失败一律由 `invokeHelper` 转成错误码写槽，**绝不把异常抛回机器码**
 * （design D5：机器码没有栈展开能力）。
 *
 * `63–68` 保留给 M2/M3，本表不登记（§6）。
 */
/**
 * `@C` 入口的公共实现体（hid → 实现分派）。
 *
 * `n` 为 0 时 `args` 允许是 null（§4「nargs=0 时可为 null」）⇒ 不做任何读。
 */
internal func helperEntry(hid: Int64, raw: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    let ctx = JitContext.wrap(raw)
    var a = Array<Int64>(if (n <= 0) { 0 } else { n }, repeat: 0)
    var i: Int64 = 0
    // 机器码在调用前已把实参区翻转为正序（args[0] 在最低地址）
    while (i < n) {
        a[i] = unsafe { args.read(i) }
        i = i + 1
    }
    invokeHelper(ctx, hid, a)
}

/** H01 `hl_len`（§6）。 */
@C
public func hl_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(1, ctx, args, n)
}
/** H02 `hl_get`（§6）。 */
@C
public func hl_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(2, ctx, args, n)
}
/** H03 `hm_len`（§6）。 */
@C
public func hm_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(3, ctx, args, n)
}
/** H04 `hm_get`（§6）。 */
@C
public func hm_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(4, ctx, args, n)
}
/** H05 `hm_get_or`（§6）。 */
@C
public func hm_get_or(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(5, ctx, args, n)
}
/** H06 `hm_has`（§6）。 */
@C
public func hm_has(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(6, ctx, args, n)
}
/** H07 `hs_len`（§6）。 */
@C
public func hs_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(7, ctx, args, n)
}
/** H08 `hs_at`（§6）。 */
@C
public func hs_at(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(8, ctx, args, n)
}
/** H09 `hs_cmp`（§6）。 */
@C
public func hs_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(9, ctx, args, n)
}
/** H10 `h_ref_eq`（§6）。 */
@C
public func h_ref_eq(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(10, ctx, args, n)
}
/** H11 `hd_cmp`（§6）。 */
@C
public func hd_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(11, ctx, args, n)
}
/** H12 `hd_is_int`（§6）。 */
@C
public func hd_is_int(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(12, ctx, args, n)
}
/** H13 `ht_cmp`（§6）。 */
@C
public func ht_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(13, ctx, args, n)
}
/** H14 `ht_field`（§6）。 */
@C
public func ht_field(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(14, ctx, args, n)
}
/** H15 `hdur_cmp`（§6）。 */
@C
public func hdur_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(15, ctx, args, n)
}
/** H16 `hdur_ticks`（§6）。 */
@C
public func hdur_ticks(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(16, ctx, args, n)
}
/** H17 `h_is_type`（§6）。 */
@C
public func h_is_type(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(17, ctx, args, n)
}
/** H18 `h_tag_of`（§6）。 */
@C
public func h_tag_of(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(18, ctx, args, n)
}
/** H19 `h_guard`（§6）。 */
@C
public func h_guard(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(19, ctx, args, n)
}
/** H20 `h_nonnull`（§6）。 */
@C
public func h_nonnull(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(20, ctx, args, n)
}
/** H21 `err_raise`（§6）。 */
@C
public func err_raise(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(21, ctx, args, n)
}
/** H22 `interrupt_poll`（§6）。 */
@C
public func interrupt_poll(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(22, ctx, args, n)
}
/** H23 `hw_check`（§6）。 */
@C
public func hw_check(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(23, ctx, args, n)
}
/** H24 `dec_add`（§6）。 */
@C
public func dec_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(24, ctx, args, n)
}
/** H25 `dec_sub`（§6）。 */
@C
public func dec_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(25, ctx, args, n)
}
/** H26 `dec_mul`（§6）。 */
@C
public func dec_mul(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(26, ctx, args, n)
}
/** H27 `dec_div`（§6）。 */
@C
public func dec_div(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(27, ctx, args, n)
}
/** H28 `dec_from_i64`（§6）。 */
@C
public func dec_from_i64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(28, ctx, args, n)
}
/** H29 `dec_from_f64`（§6）。 */
@C
public func dec_from_f64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(29, ctx, args, n)
}
/** H30 `dec_to_i64`（§6）。 */
@C
public func dec_to_i64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(30, ctx, args, n)
}
/** H31 `dec_to_f64`（§6）。 */
@C
public func dec_to_f64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(31, ctx, args, n)
}
/** H32 `str_cat`（§6）。 */
@C
public func str_cat(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(32, ctx, args, n)
}
/** H33 `to_str`（§6）。 */
@C
public func to_str(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(33, ctx, args, n)
}
/** H34 `dt_add`（§6）。 */
@C
public func dt_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(34, ctx, args, n)
}
/** H35 `dt_sub`（§6）。 */
@C
public func dt_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(35, ctx, args, n)
}
/** H36 `dur_add`（§6）。 */
@C
public func dur_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(36, ctx, args, n)
}
/** H37 `dur_sub`（§6）。 */
@C
public func dur_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(37, ctx, args, n)
}
/** H38 `dur_mul`（§6）。 */
@C
public func dur_mul(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(38, ctx, args, n)
}
/** H39 `dur_div`（§6）。 */
@C
public func dur_div(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(39, ctx, args, n)
}
/** H40 `dur_neg`（§6）。 */
@C
public func dur_neg(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(40, ctx, args, n)
}
/** H41 `range_new`（§6）。 */
@C
public func range_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(41, ctx, args, n)
}
/** H42 `range_contains`（§6）。 */
@C
public func range_contains(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(42, ctx, args, n)
}
/** H43 `list_add`（§6）。 */
@C
public func list_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(43, ctx, args, n)
}
/** H44 `map_put`（§6）。 */
@C
public func map_put(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(44, ctx, args, n)
}
/** H45 `list_insert`（§6）。 */
@C
public func list_insert(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(45, ctx, args, n)
}
/** H46 `list_set`（§6）。 */
@C
public func list_set(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(46, ctx, args, n)
}
/** H47 `list_remove`（§6）。 */
@C
public func list_remove(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(47, ctx, args, n)
}
/** H48 `map_remove`（§6）。 */
@C
public func map_remove(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(48, ctx, args, n)
}
/** H49 `map_iter_begin`（§6）。 */
@C
public func map_iter_begin(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(49, ctx, args, n)
}
/** H50 `str_sub`（§6）。 */
@C
public func str_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(50, ctx, args, n)
}
/** H51 `str_replace`（§6）。 */
@C
public func str_replace(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(51, ctx, args, n)
}
/** H52 `regex_is_match`（§6）。 */
@C
public func regex_is_match(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(52, ctx, args, n)
}
/** H53 `regex_find`（§6）。 */
@C
public func regex_find(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(53, ctx, args, n)
}
/** H54 `closure_new`（§6）。 */
@C
public func closure_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(54, ctx, args, n)
}
/** H55 `closure_fnid`（§6）。 */
@C
public func closure_fnid(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(55, ctx, args, n)
}
/** H56 `closure_cap`（§6）。 */
@C
public func closure_cap(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(56, ctx, args, n)
}
/** H57 `fn_table`（§6）。 */
@C
public func fn_table(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(57, ctx, args, n)
}
/** H58 `regex_replace_all`（§6）。 */
@C
public func regex_replace_all(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(58, ctx, args, n)
}
/** H59 `regex_replace_nth`（§6）。 */
@C
public func regex_replace_nth(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(59, ctx, args, n)
}
/** H60 `str_repeat`（§6）。 */
@C
public func str_repeat(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(60, ctx, args, n)
}
/** H61 `dt_diff`（§6）。 */
@C
public func dt_diff(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(61, ctx, args, n)
}
/** H62 `map_iter_step`（§6）。 */
@C
public func map_iter_step(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(62, ctx, args, n)
}
/** H69 `str_to_regex`（§6）。 */
@C
public func str_to_regex(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(69, ctx, args, n)
}
/** H70 `list_new`（§6）。 */
@C
public func list_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(70, ctx, args, n)
}
/** H71 `map_new`（§6）。 */
@C
public func map_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(71, ctx, args, n)
}
/** H72 `regex_replace_range`（§6）。 */
@C
public func regex_replace_range(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(72, ctx, args, n)
}

/**
 * H00 `h_dispatch`：全部内建 helper 的**统一 @C 入口**（hid 在首参）。
 *
 * JIT 机器码经此一跳调用任意 H01–H72：`x0 = hid`、`x1 = ctx`、`x2 = &args`、`x3 = argc`。
 * 语义与逐 helper `@C` 入口完全一致（同一 `helperEntry` 分派），仅省去 72 个地址。
 */
@C
public func h_dispatch(hid: Int64, ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64 {
    helperEntry(hid, ctx, args, n)
}
