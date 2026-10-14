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
 * 各个“整数 + 单位”片段分别带符号，再按顺序相加。
 * 例如 `1m-2s` 为 58 秒，`-1m2s` 为 -58 秒；首段的负号不作用于整串。
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
        while (i < value.size) {
            let start = i
            if (value[i] == b'-' || value[i] == b'+') { i++ }
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
            let scale = match (unit) {
                case b'd' => Duration.day
                case b'h' => Duration.hour
                case b'm' =>
                    if (i < value.size && value[i] == b's') {
                        i++
                        Duration.millisecond
                    } else {
                        Duration.minute
                    }
                case b's' => Duration.second
                case b'u' =>
                    if (i >= value.size || value[i] != b's') { return None }
                    i++
                    Duration.microsecond
                case b'n' =>
                    if (i >= value.size || value[i] != b's') { return None }
                    i++
                    Duration.nanosecond
                case _ => return None
            }
            duration += scale * number
        }
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
