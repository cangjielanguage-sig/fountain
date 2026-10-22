/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.base

import std.convert.*
import std.math.numeric.{BigInt, Decimal}

public interface DataParsable<T> where T <: DataParsable<T> {
    static func parse(s: String): T
    static func tryParse(s: String): ?T
}

/**
 * 整个 Duration 字符串可带一个正负号前缀，**作用于整个值**；其余是连写的“整数 + 单位”片段，
 * 例如 `-45s`、`+3s`、`-10d`、`-1m2s`（为 -62 秒）。字符串中不允许空白。
 * 单位必须从左往右严格变小（`d > h > m > s > ms > us > ns`），每个单位至多出现一次，
 * 因此 `9h10d`、`1ms1s` 这类顺序错误或重复的串会被拒绝。
 * 符号只允许出现在字符串开头——`1m-2s`、`1m+2s`、`-1m 2s` 这类段间符号按四则运算拒绝；
 * `-5`、`+3` 这类没有单位的串也不是合法的 Duration 字符串。
 */
extend Duration <: DataParsable<Duration> {
    public static func parse(s: String): Duration {
        doTryParse(s).getOrThrow()
    }
    public static func tryParse(s: String): ?Duration {
        // 与 Int64.tryParse 对齐（实测其对超长值返回 None，不抛异常）：
        // 不能解析、或数值超出 Duration 表示范围时返回 None。
        try {
            doTryParse(s)
        } catch (_: ArithmeticException) {
            None
        }
    }
    // 解析核心：不能解析的字符串返回 None；数值超出 Duration 表示范围时抛 ArithmeticException。
    // 这里刻意不沿用昨夜合入的「循环内就地 catch 溢出并返回 None」写法：那种写法把溢出无声地
    // 吞成 None，核心解析与 tryParse 之间的分层就没了。改由本函数抛出、tryParse 统一收敛为 None，
    // 是为了保持与其他类型的 tryParse 语义一致——Int64/UInt64 等的 tryParse 同样是
    // 「不能解析、数值超出表示范围 → None」，由底层解析负责报错。
    private static func doTryParse(value: String): ?Duration {
        if (value.isEmpty()) { return None }
        var duration = Duration.Zero
        var i = 0
        var parsed = false
        var negative = false
        var lastRank = -1
        while (i < value.size) {
            let start = i
            if (value[i] == b'-' || value[i] == b'+') {
                // 正负号只允许出现在字符串最开头，且作用于整个值；段间符号是四则运算（`1m-2s`），拒绝
                if (start != 0) { return None }
                negative = value[i] == b'-'
                i++
            }
            let digits = i
            while (i < value.size && value[i] >= b'0' && value[i] <= b'9') { i++ }
            if (i == digits || i == value.size) { return None }
            let numberStart = if (value[start] == b'+') { start + 1 } else { start }
            let number = match (Int64.tryParse(value[numberStart..i])) {
                case Some(n) => n
                case None => return None
            }
            let unit = value[i]
            i++
            // 单位必须从左往右严格变小：d > h > m > s > ms > us > ns（每个单位至多出现一次）
            let (scale, rank) = match (unit) {
                case b'd' => (Duration.day, 0)
                case b'h' => (Duration.hour, 1)
                case b'm' =>
                    if (i < value.size && value[i] == b's') {
                        i++
                        (Duration.millisecond, 4)
                    } else {
                        (Duration.minute, 2)
                    }
                case b's' => (Duration.second, 3)
                case b'u' =>
                    if (i >= value.size || value[i] != b's') { return None }
                    i++
                    (Duration.microsecond, 5)
                case b'n' =>
                    if (i >= value.size || value[i] != b's') { return None }
                    i++
                    (Duration.nanosecond, 6)
                case _ => return None
            }
            if (rank <= lastRank) { return None }
            lastRank = rank
            // 开头的负号作用于整串：首段沿用它自己的符号解析，其余片段按负值累加（-(x + y) == -x - y）。
            // 这里用「加上负值」而不是「减法」：Duration 的减法在结果落到 Int64.Min 秒时会误报溢出
            // （实测 `(-Max 秒) - 1s` 抛 ArithmeticException，而 `(-Max 秒) + (second * -1)` 正常），
            // 用加法才能保证 `-106751991167300d15h30m8s` 这类 Min 秒的 toString 输出也被读回
            if (parsed && negative) {
                duration += scale * (-number)
            } else {
                duration += scale * number
            }
            parsed = true
        }
        if (!parsed) { return None }
        duration
    }
}

extend Int64 <: DataParsable<Int64> {}

extend UInt64 <: DataParsable<UInt64> {}

extend Int32 <: DataParsable<Int32> {}

extend UInt32 <: DataParsable<UInt32> {}

extend Int16 <: DataParsable<Int16> {}

extend UInt16 <: DataParsable<UInt16> {}

extend Int8 <: DataParsable<Int8> {}

extend UInt8 <: DataParsable<UInt8> {}

extend Float64 <: DataParsable<Float64> {}

extend Float32 <: DataParsable<Float32> {}

extend Float16 <: DataParsable<Float16> {}

extend Bool <: DataParsable<Bool> {}

extend BigInt <: DataParsable<BigInt> {}

extend Decimal <: DataParsable<Decimal> {}

extend String <: DataParsable<String> {
    public static func parse(s: String): String {
        s
    }
    public static func tryParse(s: String): ?String {
        s
    }
}
