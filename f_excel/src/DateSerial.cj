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

import std.time.DateTime

private let NANOS_PER_DAY: Int64 = 86_400_000_000_000

/** UTC 日序号（与本地时区无关）。 */
internal func utcDayNumber(year: Int64, month: Int64, day: Int64): Int64 {
    DateTime.ofUTC(year: year, month: month, dayOfMonth: day, hour: 0, minute: 0, second: 0, nanosecond: 0)
        .toUnixTimeStamp()
        .toNanoseconds() / NANOS_PER_DAY
}

/** Excel 序列号（日期部分，0 起）：1900 基准含 1900-02-29 的历史 bug。 */
internal func excelSerialDays(year: Int64, month: Int64, day: Int64, date1904: Bool): Int64 {
    let target = utcDayNumber(year, month, day)
    if (date1904) {
        return target - utcDayNumber(1904, 1, 1)
    }
    var days = target - utcDayNumber(1899, 12, 31)
    if (target >= utcDayNumber(1900, 3, 1)) {
        days++
    }
    days
}

/**
 * `DateTime` → Excel 序列号（秒精度，毫秒截断）。
 *
 * 只取日期字段与时分秒，不做时区换算——Excel 的日期是"墙上时间"。
 */
internal func serialFromDateTime(value: DateTime, date1904: Bool): Float64 {
    let days = excelSerialDays(value.year, value.month.toInteger(), value.dayOfMonth, date1904)
    let seconds = value.hour * 3600 + value.minute * 60 + value.second
    Float64(days) + Float64(seconds) / 86400.0
}

/**
 * 日期样式选择（设计 6.x）：全天 → 14；只有时间 → 20；日期 + 时间 → 22。
 */
internal func dateStyleFor(value: DateTime, date1904: Bool): Int64 {
    let seconds = value.hour * 3600 + value.minute * 60 + value.second
    let days = excelSerialDays(value.year, value.month.toInteger(), value.dayOfMonth, date1904)
    if (seconds == 0) {
        return 14
    }
    if (days == 0) {
        return 20
    }
    22
}
