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
package fountain::f_zip

import std.time.{DateTime, TimeZone}

/**
 * DOS 时间编解码。
 *
 * ```
 * time: bit15-11 时(0-23) | bit10-5 分(0-59) | bit4-0 秒/2(0-29)
 * date: bit15-9 年-1980   | bit8-5 月(1-12)  | bit4-0 日(1-31)
 * ```
 *
 * 秒只有 2 秒精度，这是格式限制不是 bug；编码时向偶数秒截断。
 */
internal func encodeDosTime(dt: DateTime): UInt16 {
    UInt16((dt.hour << 11) | (dt.minute << 5) | (dt.second / 2))
}

internal func encodeDosDate(dt: DateTime): UInt16 {
    let year = dt.year
    let clamped = if (year < 1980) {
        0
    } else if (year > 2107) {
        127
    } else {
        year - 1980
    }
    UInt16((clamped << 9) | (dt.month.toInteger() << 5) | dt.dayOfMonth)
}

/**
 * 解码 DOS 时间。`dosDate == 0`（年度、月份、日期全 0）视为"没有时间信息"，
 * 返回 `None` 而不是伪造一个 1980-01-01。
 */
internal func decodeDosDateTime(dosTime: UInt16, dosDate: UInt16): ?DateTime {
    if (dosDate == 0) {
        return None<DateTime>
    }
    let year = 1980 + Int64((dosDate >> 9) & 0x7F)
    let month = Int64((dosDate >> 5) & 0x0F)
    let day = Int64(dosDate & 0x1F)
    let hour = Int64((dosTime >> 11) & 0x1F)
    let minute = Int64((dosTime >> 5) & 0x3F)
    let second = Int64((dosTime & 0x1F) * 2)
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) {
        return None<DateTime>
    }
    try {
        Some(
            DateTime.of(
                year: year,
                month: month,
                dayOfMonth: day,
                hour: hour,
                minute: minute,
                second: second,
                timeZone: TimeZone.Local
            )
        )
    } catch (_: Exception) {
        None<DateTime>
    }
}
