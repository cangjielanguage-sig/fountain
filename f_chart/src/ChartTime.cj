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
package fountain::f_chart

import std.convert.*

/**
 * 轻量日期换算：`YYYY-MM-DD`（可带时间部分，忽略时间）↔ 1970-01-01 起的天数。
 *
 * f_chart 的时间轴只需要「按天定位 + 日期刻度」，不引入完整时区/日历库。
 */
internal class ChartTime {
    /** 解析日期为 1970-01-01 起的天数。 */
    static func parseDays(text: String, path: String): Float64 {
        let bytes = text.toArray()
        if (bytes.size < 10 || bytes[4] != b'-' || bytes[7] != b'-') {
            throw chartInvalidValue(path, "日期格式应为 YYYY-MM-DD")
        }
        let year = parseIntOrThrow(text[0..4], path)
        let month = parseIntOrThrow(text[5..7], path)
        let day = parseIntOrThrow(text[8..10], path)
        if (month < 1 || month > 12 || day < 1 || day > 31) {
            throw chartInvalidValue(path, "日期超出范围")
        }
        Float64(daysFromCivil(year, month, day))
    }

    /** 把天数格式化为 `YYYY-MM-DD`。 */
    static func formatDays(days: Float64): String {
        let date = civilFromDays(Int64(days))
        "${pad(date[0], 4)}-${pad(date[1], 2)}-${pad(date[2], 2)}"
    }

    /** 把天数拆成 `[年, 月, 日]`。 */
    static func partsOfDays(days: Float64): Array<Int64> {
        civilFromDays(Int64(days))
    }

    private static func parseIntOrThrow(text: String, path: String): Int64 {
        try {
            Int64.parse(text)
        } catch (_: Exception) {
            throw chartInvalidValue(path, "日期中的数字不合法")
        }
    }

    private static func daysFromCivil(year: Int64, month: Int64, day: Int64): Int64 {
        var y = year
        if (month <= 2) {
            y -= 1
        }
        let era = y / 400
        let yoe = y - era * 400
        let mp = if (month > 2) { month - 3 } else { month + 9 }
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146097 + doe - 719468
    }

    private static func civilFromDays(days: Int64): Array<Int64> {
        let z = days + 719468
        let era = z / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = if (mp < 10) { mp + 3 } else { mp - 9 }
        if (m <= 2) {
            y += 1
        }
        [y, m, d]
    }

    private static func pad(value: Int64, width: Int64): String {
        let text = value.toString()
        var result = text
        while (result.toArray().size < width) {
            result = "0" + result
        }
        result
    }
}
