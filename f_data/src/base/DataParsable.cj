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
        tryParse(s).getOrThrow {DataParsableException('${s} cannot be parsed to ${TypeInfo.of<Duration>()}')}
    }
    public static func tryParse(s: String): ?Duration {
        if (s.isEmpty()) { return None }
        var duration = Duration.Zero
        var i = 0
        while (i < s.size) {
            let start = i
            if (s[i] == b'-' || s[i] == b'+') { i++ }
            let digits = i
            while (i < s.size && s[i] >= b'0' && s[i] <= b'9') { i++ }
            if (i == digits || i == s.size) { return None }
            let numberStart = if (s[start] == b'+') { start + 1 } else { start }
            let value = match (Int64.tryParse(s[numberStart..i])) {
                case Some(number) => number
                case None => return None
            }
            let unit = s[i]
            i++
            let scale = match (unit) {
                case b'd' => Duration.day
                case b'h' => Duration.hour
                case b'm' =>
                    if (i < s.size && s[i] == b's') {
                        i++
                        Duration.millisecond
                    } else {
                        Duration.minute
                    }
                case b's' => Duration.second
                case b'u' =>
                    if (i >= s.size || s[i] != b's') { return None }
                    i++
                    Duration.microsecond
                case b'n' =>
                    if (i >= s.size || s[i] != b's') { return None }
                    i++
                    Duration.nanosecond
                case _ => return None
            }
            try {
                duration += scale * value
            } catch (_: ArithmeticException) {
                return None
            }
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
