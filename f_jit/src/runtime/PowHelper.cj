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

import fountain::f_jit.base.ErrCode

/**
 * H84 `ipow`：`(Int64, Int64) → Int64`，`**` 的运行时实现。
 *
 * **语义对齐仓颉**（`Appendix/operator.md`：`**` 为 `Int64 ** UInt64`——指数无符号）：
 * 方言没有无符号类型，因此把"指数无符号"映射为"**指数必须非负**"：
 *
 * | 情形 | 结果 |
 * |---|---|
 * | `exp < 0` | `ERR_ARG_MISMATCH(14)`（仓颉侧该情形类型上不可表达） |
 * | `exp == 0` | `1`（含 `0 ** 0`） |
 * | 结果溢出 | `ERR_OVERFLOW_I64(3)`（仓颉：静态可判编译期报错、否则运行期抛异常） |
 *
 * 算法为**快速幂**（O(log exp)）：`2 ** 1_000_000_000` 不会线性空转；每次乘法都做溢出判定。
 * 三引擎（解释器 / x86_64 / aarch64）共用本实现 ⇒ 结果与错误码逐位一致（I7）。
 */
internal func ipow(ctx: JitContext, a: Array<Int64>): Int64 {
    let base = argAt(a, 0)
    let exp = argAt(a, 1)
    if (exp < 0) {
        failWith(ErrCode.ARG_MISMATCH)
    }
    if (exp == 0) {
        return 1
    }
    var result: Int64 = 1
    var b = base
    var e = exp
    while (e > 0) {
        if ((e & 1) == 1) {
            result = powMulChecked(result, b)
        }
        e = e >> 1
        if (e > 0) {
            b = powMulChecked(b, b)
        }
    }
    result
}

/** 乘法 + 溢出判定：溢出 → 3（含 `INT_MIN * -1`）。 */
private func powMulChecked(a: Int64, b: Int64): Int64 {
    if (a == 0 || b == 0) {
        return 0
    }
    if ((a == -1 && b == Int64.Min) || (b == -1 && a == Int64.Min)) {
        failWith(ErrCode.OVERFLOW_I64)
    }
    try {
        a * b
    } catch (_: Exception) {
        // 仓颉整数乘法溢出按默认策略抛异常 ⇒ 归一到 3
        failWith(ErrCode.OVERFLOW_I64)
    }
}
