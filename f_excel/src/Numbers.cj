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
package fountain::f_excel

import std.convert.*

/**
 * 数字写成「能唯一还原该 `Float64` 的最短十进制串」。
 *
 * - 整数值写 `Int64` 形式（`1.0` → `"1"`）；
 * - 其余用精度 1..17 的 `g` 格式逐个试，第一个能解析回原值的即最短；
 * - `NaN` / `±Inf` 抛（xlsx 无法表达）。
 */
internal func formatNumber(value: Float64): String {
    if (value.isNaN()) {
        throw ExcelException("NaN 无法写入 xlsx")
    }
    if (value.isInf()) {
        throw ExcelException("Infinity 无法写入 xlsx")
    }
    if (value == 0.0) {
        return "0"
    }
    if (value > -9_007_199_254_740_992.0 && value < 9_007_199_254_740_992.0) {
        let truncated = Int64(value)
        if (Float64(truncated) == value) {
            return truncated.toString()
        }
    }
    var precision = 1
    while (precision <= 17) {
        let candidate = value.format(".${precision}g")
        let back = try {
            Float64.parse(candidate)
        } catch (_: Exception) {
            value + 1.0
        }
        if (back == value) {
            return candidate
        }
        precision++
    }
    value.format(".17g")
}
