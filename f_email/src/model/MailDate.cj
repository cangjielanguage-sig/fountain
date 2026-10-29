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
package fountain::f_email.model

import std.collection.ArrayList
import std.time.{DateTime, DayOfWeek, Month, TimeZone}

/**
 * RFC 5322 日期。
 *
 * 解析比生成宽容：星期可省略、月份大小写不敏感、两位年份按 RFC 规则换算、
 * 缺失时区视为 `+0000` 并记告警（**不按本地时区猜**，猜错会把邮件的先后顺序弄反）。
 * 非法日期在宽松模式回退到 `1970-01-01` 并记告警，严格模式抛 [MimeException]。
 */
public class MailDate <: ToString {
    private let value: DateTime
    public let offsetMinutes: Int32
    /** 解析过程中产生的告警（缺失时区、回退等），供调用方决定是否记录。 */
    public let warnings: Array<String>

    public init(dateTime: DateTime, offsetMinutes!: Int32 = 0) {
        this.value = dateTime
        this.offsetMinutes = offsetMinutes
        this.warnings = []
    }

    private init(dateTime: DateTime, offsetMinutes: Int32, warnings: Array<String>) {
        this.value = dateTime
        this.offsetMinutes = offsetMinutes
        this.warnings = warnings
    }

    public static func now(): MailDate {
        let local = DateTime.now()
        // TimeZone 不暴露偏移量，用"把本地墙上时间按 UTC 重建"的差值反推。
        let wallAsUtc = DateTime.of(
            year: local.year,
            month: monthValue(local.month),
            dayOfMonth: local.dayOfMonth,
            hour: local.hour,
            minute: local.minute,
            second: local.second,
            timeZone: TimeZone.UTC
        )
        let minutes = (wallAsUtc.toUnixTimeStamp() - local.toUnixTimeStamp()).toMinutes()
        MailDate(local, offsetMinutes: Int32(minutes))
    }

    private static func monthValue(month: Month): Int64 {
        match (month) {
            case Month.January => 1
            case Month.February => 2
            case Month.March => 3
            case Month.April => 4
            case Month.May => 5
            case Month.June => 6
            case Month.July => 7
            case Month.August => 8
            case Month.September => 9
            case Month.October => 10
            case Month.November => 11
            case Month.December => 12
        }
    }

    public static func parse(text: String): MailDate {
        parse(text, strict: false)
    }

    /**
     * 严格模式：任何无法解析的日期都抛 [MimeException]，不静默回退。
     */
    public static func parse(text: String, strict!: Bool): MailDate {
        let warnings = ArrayList<String>()
        let cleaned = stripComments(text)
        let tokens = cleaned.trimAscii().split(" ", removeEmpty: true)
        var i = 0
        if (tokens.size > 0 && tokens[0].endsWith(",")) {
            i = 1
        } else if (tokens.size > 0 && isWeekday(tokens[0])) {
            // 星期省略逗号也接受
            i = 1
        }
        if (tokens.size - i < 3) {
            return failed(text, strict, warnings)
        }
        let day = parseInt(tokens[i])
        let month = monthNumber(tokens[i + 1])
        var yearText = tokens[i + 2]
        i += 3
        if (day.isNone() || month == 0) {
            return failed(text, strict, warnings)
        }
        // 年份后面可能直接跟时间
        var year = parseInt(yearText)
        if (year.isNone()) {
            return failed(text, strict, warnings)
        }
        var yearValue = year.getOrThrow()
        if (yearText.size == 2) {
            yearValue = if (yearValue <= 49) {
                2000 + yearValue
            } else {
                1900 + yearValue
            }
        }
        var hour = 0
        var minute = 0
        var second = 0
        if (i < tokens.size && tokens[i].contains(":")) {
            let parts = tokens[i].split(":")
            if (parts.size < 2) {
                return failed(text, strict, warnings)
            }
            hour = parseInt(parts[0]).getOrThrow()
            minute = parseInt(parts[1]).getOrThrow()
            if (parts.size >= 3) {
                second = parseInt(parts[2]).getOrThrow()
            }
            i += 1
        }
        var offset = 0
        if (i < tokens.size) {
            let zone = parseZone(tokens[i])
            if (zone.isNone()) {
                warnings.add("无法识别的时区：${tokens[i]}，按 +0000 处理")
            } else {
                offset = zone.getOrThrow()
            }
            i += 1
        } else {
            warnings.add("日期缺少时区，按 +0000 处理")
        }
        try {
            let dateTime = DateTime.of(
                year: yearValue,
                month: month,
                dayOfMonth: day.getOrThrow(),
                hour: hour,
                minute: minute,
                second: second,
                timeZone: fixedZone(offset)
            )
            MailDate(dateTime, Int32(offset), warnings.toArray())
        } catch (e: Exception) {
            failed(text, strict, warnings)
        }
    }

    public prop dateTime: DateTime {
        get() {
            value
        }
    }

    /** 本地时间字段（即原文里写的那个"墙上时间"）对应的 UTC 时刻。 */
    public func toUtc(): DateTime {
        value.inTimeZone(TimeZone.UTC)
    }

    public func toString(): String {
        let weekday = weekdayName(value.dayOfWeek)
        let month = monthName(value.month)
        let zone = formatOffset(offsetMinutes)
        "${weekday}, ${value.dayOfMonth} ${month} ${value.year} ${pad2(value.hour)}:${pad2(value.minute)}:${pad2(value.second)} ${zone}"
    }

    // ---------- 内部 ----------

    private static func failed(text: String, strict: Bool, warnings: ArrayList<String>): MailDate {
        if (strict) {
            throw MimeException("无法解析日期：${text}")
        }
        warnings.add("无法解析日期，回退到 1970-01-01：${text}")
        let epoch = DateTime.of(year: 1970, month: 1, dayOfMonth: 1, timeZone: TimeZone.UTC)
        MailDate(epoch, 0, warnings.toArray())
    }

    private static func fixedZone(offsetMinutes: Int64): TimeZone {
        TimeZone("UTC${formatOffset(Int32(offsetMinutes))}", Duration.minute * offsetMinutes)
    }

    private static func formatOffset(minutes: Int32): String {
        let sign = if (minutes < 0) {
            "-"
        } else {
            "+"
        }
        let abs = if (minutes < 0) {
            -Int64(minutes)
        } else {
            Int64(minutes)
        }
        "${sign}${pad2(abs / 60)}${pad2(abs % 60)}"
    }

    private static func pad2(value: Int64): String {
        if (value < 10) {
            "0${value}"
        } else {
            "${value}"
        }
    }

    private static func parseInt(text: String): ?Int64 {
        if (text.size == 0) {
            return None
        }
        for (c in text.toArray()) {
            if (c < b'0' || c > b'9') {
                return None
            }
        }
        var value: Int64 = 0
        for (c in text.toArray()) {
            value = value * 10 + Int64(c - b'0')
        }
        Some(value)
    }

    private static func isWeekday(text: String): Bool {
        let lower = text.trimAscii().trimEnd(",").toAsciiLower()
        for (name in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]) {
            if (lower.startsWith(name)) {
                return true
            }
        }
        false
    }

    private static func monthNumber(text: String): Int64 {
        let lower = text.trimAscii().toAsciiLower()
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var i = 0
        while (i < names.size) {
            if (lower.startsWith(names[i])) {
                return i + 1
            }
            i += 1
        }
        0
    }

    private static func monthName(month: Month): String {
        match (month) {
            case Month.January => "Jan"
            case Month.February => "Feb"
            case Month.March => "Mar"
            case Month.April => "Apr"
            case Month.May => "May"
            case Month.June => "Jun"
            case Month.July => "Jul"
            case Month.August => "Aug"
            case Month.September => "Sep"
            case Month.October => "Oct"
            case Month.November => "Nov"
            case Month.December => "Dec"
        }
    }

    private static func weekdayName(day: DayOfWeek): String {
        match (day) {
            case DayOfWeek.Monday => "Mon"
            case DayOfWeek.Tuesday => "Tue"
            case DayOfWeek.Wednesday => "Wed"
            case DayOfWeek.Thursday => "Thu"
            case DayOfWeek.Friday => "Fri"
            case DayOfWeek.Saturday => "Sat"
            case DayOfWeek.Sunday => "Sun"
        }
    }

    private static func parseZone(text: String): ?Int64 {
        let upper = text.trimAscii().toAsciiUpper()
        match (upper) {
            case "UT" => return Some(0)
            case "GMT" => return Some(0)
            case "Z" => return Some(0)
            case "EST" => return Some(-300)
            case "EDT" => return Some(-240)
            case "CST" => return Some(-360)
            case "CDT" => return Some(-300)
            case "MST" => return Some(-420)
            case "MDT" => return Some(-360)
            case "PST" => return Some(-480)
            case "PDT" => return Some(-420)
            case _ => ()
        }
        if (upper.size < 3) {
            return None
        }
        let sign = upper[0]
        if (sign != b'+' && sign != b'-') {
            return None
        }
        var body = upper[1..upper.size].replace(":", "")
        if (body.size != 4) {
            return None
        }
        let hours = parseInt(body[0..2])
        let minutes = parseInt(body[2..4])
        if (hours.isNone() || minutes.isNone()) {
            return None
        }
        let h = hours.getOrThrow()
        let m = minutes.getOrThrow()
        if (h > 23 || m > 59) {
            return None
        }
        let total = h * 60 + m
        if (sign == b'-') {
            Some(-total)
        } else {
            Some(total)
        }
    }

    /** 去掉头注释 `(...)`，支持嵌套与非转义括号。 */
    private static func stripComments(text: String): String {
        let out = ArrayList<Rune>()
        var depth = 0
        var escaped = false
        for (ch in text.runes()) {
            if (escaped) {
                escaped = false
                if (depth == 0) {
                    out.add(ch)
                }
                continue
            }
            if (ch == r'\\') {
                escaped = true
                if (depth == 0) {
                    out.add(ch)
                }
                continue
            }
            if (ch == r'(') {
                depth += 1
                continue
            }
            if (ch == r')') {
                if (depth > 0) {
                    depth -= 1
                }
                continue
            }
            if (depth == 0) {
                out.add(ch)
            }
        }
        String(out.toArray())
    }
}
