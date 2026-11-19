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

import std.collection.ArrayList
import std.time.DateTime
import fountain::f_base.StringGenerator

/** 内置日期格式：14–22、45–47。 */
internal func isBuiltinDateFormat(numFmtId: Int64): Bool {
    (numFmtId >= 14 && numFmtId <= 22) || (numFmtId >= 45 && numFmtId <= 47)
}

/** 方括号内容全为 h/m/s（如 `[h]` / `[hh]:mm`）→ 时长标记。 */
internal func hasElapsedMarker(code: String): Bool {
    let runes = ArrayList<Rune>()
    for (r in code.runes()) {
        runes.add(r)
    }
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'[') {
            var j = i + 1
            var content = ""
            while (j < runes.size && runes[j] != r']') {
                content += runes[j].toString()
                j++
            }
            if (j < runes.size && !content.isEmpty()) {
                var allElapsed = true
                for (r in content.runes()) {
                    let lower = r.toString().toAsciiLower()
                    if (lower != "h" && lower != "m" && lower != "s") {
                        allElapsed = false
                        break
                    }
                }
                if (allElapsed) {
                    return true
                }
            }
            i = j + 1
        } else {
            i++
        }
    }
    false
}

/**
 * 自定义格式串是否是日期/时间。
 *
 * 顺序：先识别 `[h]` 类时长标记，再净化（去 `[...]` / `"..."` / `\x` / `_x` / `*x`），
 * 净化后出现 `y/m/d/h/s` 且（有 `-` `/` `:` 或含 `y`/`d`）即判为日期。
 */
internal func isDateFormatCode(code: String): Bool {
    let runes = ArrayList<Rune>()
    for (r in code.runes()) {
        runes.add(r)
    }
    let cleaned = StringGenerator()
    var i: Int64 = 0
    while (i < runes.size) {
        let r = runes[i]
        match (r) {
            case r'[' =>
                var j = i + 1
                while (j < runes.size && runes[j] != r']') {
                    j++
                }
                i = j + 1
            case r'"' =>
                var j = i + 1
                while (j < runes.size && runes[j] != r'"') {
                    j++
                }
                i = j + 1
            case r'\\' => i += 2
            case r'_' => i += 2
            case r'*' => i += 2
            case _ =>
                cleaned.append(r.toString().toAsciiLower())
                i++
        }
    }
    let text = cleaned.toString()
    var hasLetter = false
    for (r in text.runes()) {
        if (r == r'y' || r == r'm' || r == r'd' || r == r'h' || r == r's') {
            hasLetter = true
            break
        }
    }
    if (!hasLetter) {
        return false
    }
    text.contains('-') || text.contains('/') || text.contains(':') || text.contains('y') || text.contains('d')
}

/**
 * Excel 序列号 → `DateTime`（UTC）。
 *
 * 1900 基准的 serial 60 是"1900-02-29"这个不存在的日子，返回 `None`（调用方保留 `Number`）。
 */
internal func dateTimeFromSerial(serial: Float64, date1904: Bool): ?DateTime {
    if (serial < 0.0 || serial.isNaN() || serial.isInf()) {
        return None<DateTime>
    }
    if (!date1904 && serial >= 60.0 && serial < 61.0) {
        return None<DateTime>
    }
    let whole = Int64(serial)
    let fraction = serial - Float64(whole)
    var seconds = Int64(fraction * 86400.0 + 0.5)
    var days = whole
    if (seconds >= 86400) {
        seconds -= 86400
        days++
    }
    let baseDay = if (date1904) {
        utcDayNumber(1904, 1, 1)
    } else if (whole <= 59) {
        utcDayNumber(1899, 12, 31)
    } else {
        utcDayNumber(1899, 12, 30)
    }
    let epochSeconds = (baseDay + days) * 86400 + seconds
    Some(DateTime.ofEpoch(second: epochSeconds, nanosecond: 0))
}
