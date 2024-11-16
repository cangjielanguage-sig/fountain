/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import std.collection.ArrayList
import std.convert.Parsable
import std.reflect.TypeInfo
import f_data.exception.DataParsableException

public interface DataParsable<T> where T <: DataParsable<T> {
    static func parse(s: String): T {
        tryParse(s).getOrThrow {DataParsableException('${s} cannot be parsed to ${TypeInfo.of<T>()}')}
    }
    static func tryParse(s: String): ?T
}

extend Duration <: DataParsable<Duration> {
    public static func tryParse(s: String): ?Duration {
        let bytes = ArrayList<Byte>()
        var duration = Duration.Zero
        var i = 0
        while (i < s.size) {
            let r = s[i]
            i++
            duration += match (r) {
                case x where x == b'-' || (x >= b'0' && x <= b'9') =>
                    bytes.append(x)
                    i++
                    continue
                case b'd' => Duration.day
                case b'h' => Duration.hour
                case b'm' =>
                    if (s[i] == b's') {
                        i++
                        Duration.millisecond
                    } else {
                        Duration.minute
                    }
                case b's' => Duration.second
                case b'u' where s[i] == b's' =>
                    i++ 
                    Duration.microsecond
                case b'n' where s[i] == b's' =>
                    i++
                    Duration.nanosecond
                case _ => 
                    throw DataParsableException('${s} cannot be parsed to Duration')
            } * Int64.tryParse(String.fromUtf8(bytes.toArray())).getOrThrow {DataParsableException('${s} cannot be parsed to Duration')}
        }
        duration
    }
}
