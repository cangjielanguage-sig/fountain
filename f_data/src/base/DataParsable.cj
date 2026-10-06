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

extend Duration <: DataParsable<Duration> {
    public static func parse(s: String): Duration {
        tryParse(s).getOrThrow {DataParsableException('${s} cannot be parsed to ${TypeInfo.of<Duration>()}')}
    }
    public static func tryParse(s: String): ?Duration {
        //约定（bug-cross.md 的 X-2）：单位链 d/h/m/s/ms/us/ns；数字段可带负号、可多段拼接（1d2h）；
        //非法输入返回 None（由调用方回退默认值），不抛异常。
        //修复要点：原实现数字分支多了一次 i++（吃掉数字后面的字符 ⇒ "45s"→4s、"1m"→0），
        //且非法输入直接抛异常、读到单位后未清空 bytes、单位分支取 s[i] 无边界检查。
        if (s.isEmpty()) {
            return None<Duration>
        }
        let bytes = ArrayList<Byte>()
        var duration = Duration.Zero
        var i = 0
        while (i < s.size) {
            let r = s[i]
            i++
            if (r == b'-' || (r >= b'0' && r <= b'9')) {
                //数字（含负号）先攒着，读到单位时再结算
                bytes.add(r)
                continue
            }
            let unit = match (r) {
                case b'd' => Duration.day
                case b'h' => Duration.hour
                case b'm' => if (i < s.size && s[i] == b's') {
                    i++
                    Duration.millisecond
                } else {
                    Duration.minute
                }
                case b's' => Duration.second
                case b'u' => if (i < s.size && s[i] == b's') {
                    i++
                    Duration.microsecond
                } else {
                    return None<Duration>
                }
                case b'n' => if (i < s.size && s[i] == b's') {
                    i++
                    Duration.nanosecond
                } else {
                    return None<Duration>
                }
                case _ => return None<Duration>
            }
            if (let Some(n) <- Int64.tryParse(String.unsafeUtf8(bytes.unsafeData()))) {
                duration += unit * n
            } else {
                return None<Duration>
            }
            //结算完清空，供下一段使用（如 1d2h）
            bytes.clear()
        }
        if (bytes.isEmpty()) {
            duration
        } else {
            //只有数字、没给单位
            None<Duration>
        }
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