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
import std.math.*
import fountain::f_base.StringGenerator

// ---------------------------------------------------------------- 文本

internal func runesOf(text: String): ArrayList<Rune> {
    let list = ArrayList<Rune>()
    for (r in text.runes()) {
        list.add(r)
    }
    list
}

internal func runesJoin(list: ArrayList<Rune>, start: Int64, end: Int64): String {
    let out = StringGenerator()
    var i = start
    let stop = if (end > list.size) { list.size } else { end }
    while (i < stop) {
        if (i >= 0) {
            out.append(list[i])
        }
        i++
    }
    out.toString()
}

internal func fnConcat(ev: Evaluator, args: Array<Expr>): CalcValue {
    let out = StringGenerator()
    for (i in 0..args.size) {
        match (ev.arg(args, i)) {
            case Error(e) => return CalcValue.Error(e)
            case ArrayValue(rows) =>
                for (row in rows) {
                    for (item in row) {
                        out.append<String>(calcToText(item))
                    }
                }
            case value => out.append<String>(calcToText(value))
        }
    }
    CalcValue.Text(out.toString())
}

internal func fnLen(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var count: Int64 = 0
    for (_ in calcToText(scalarize(value)).runes()) {
        count++
    }
    CalcValue.Number(Float64(count))
}

internal func fnLeftRight(ev: Evaluator, args: Array<Expr>, left: Bool): CalcValue {
    let textValue = ev.arg(args, 0)
    match (firstError([textValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let text = calcToText(scalarize(textValue))
    var count: Int64 = 1
    if (args.size > 1) {
        let countValue = ev.arg(args, 1)
        match (firstError([countValue])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        count = match (calcToNumber(scalarize(countValue))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (count < 0) {
        return CalcValue.Error(CalcError.Value)
    }
    let runes = runesOf(text)
    if (left) {
        return CalcValue.Text(runesJoin(runes, 0, count))
    }
    let start = if (count >= runes.size) { 0 } else { runes.size - count }
    CalcValue.Text(runesJoin(runes, start, runes.size))
}

internal func fnMid(ev: Evaluator, args: Array<Expr>): CalcValue {
    let textValue = ev.arg(args, 0)
    let startValue = ev.arg(args, 1)
    let lenValue = ev.arg(args, 2)
    match (firstError([textValue, startValue, lenValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let text = calcToText(scalarize(textValue))
    let start = match (calcToNumber(scalarize(startValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let length = match (calcToNumber(scalarize(lenValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (start < 1 || length < 0) {
        return CalcValue.Error(CalcError.Value)
    }
    let runes = runesOf(text)
    CalcValue.Text(runesJoin(runes, start - 1, start - 1 + length))
}

internal func fnTrim(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let text = calcToText(scalarize(value))
    let out = StringGenerator()
    var pendingSpace = false
    var started = false
    for (r in text.runes()) {
        if (r == r' ') {
            if (started) {
                pendingSpace = true
            }
        } else {
            if (pendingSpace) {
                out.append<String>(" ")
                pendingSpace = false
            }
            out.append(r)
            started = true
        }
    }
    CalcValue.Text(out.toString())
}

internal func fnCase(ev: Evaluator, args: Array<Expr>, upper: Bool): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let text = calcToText(scalarize(value))
    CalcValue.Text(if (upper) { text.toAsciiUpper() } else { text.toAsciiLower() })
}

internal func fnText(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = ev.arg(args, 0)
    let patternValue = ev.arg(args, 1)
    match (firstError([value, patternValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let pattern = calcToText(scalarize(patternValue))
    match (scalarize(value)) {
        case Text(text) => CalcValue.Text(text)
        case Empty => CalcValue.Text("")
        case Boolean(v) => CalcValue.Text(if (v) { "TRUE" } else { "FALSE" })
        case Number(_) =>
            let number = match (calcToNumber(scalarize(value))) {
                case Some(v) => v
                case None => return CalcValue.Error(CalcError.Value)
            }
            CalcValue.Text(formatByPattern(number, pattern))
        case Error(e) => CalcValue.Error(e)
        case _ => CalcValue.Error(CalcError.Value)
    }
}

/**
 * `TEXT` 的最小格式子集：`0` / `0.00` / `#,##0` / `0%` / `yyyy-mm-dd` / `hh:mm:ss`。
 *
 * 完整格式串引擎属于 M3；未知格式退化为最短往返数字，**不报错**。
 */
private func formatByPattern(value: Float64, pattern: String): String {
    var code = pattern
    var negative = value < 0.0
    let absValue = abs(value)
    let sections = code.split(";")
    if (sections.size > 1 && negative) {
        code = sections[1]
        negative = false
    }
    let lower = code.toAsciiLower()
    if (lower.contains("y") || lower.contains("d") || lower.contains("h") || lower.contains("m") && lower.contains(":")) {
        let date = match (dateTimeFromSerial(value, false)) {
            case Some(v) => v
            case None => return formatNumber(value)
        }
        var text = code
        text = text.replace("yyyy", padLeft(date.year.toString(), 4, "0"))
        text = text.replace("yy", padLeft((date.year % 100).toString(), 2, "0"))
        text = text.replace("mm", padLeft(date.month.toInteger().toString(), 2, "0"))
        text = text.replace("m", date.month.toInteger().toString())
        text = text.replace("dd", padLeft(date.dayOfMonth.toString(), 2, "0"))
        text = text.replace("d", date.dayOfMonth.toString())
        text = text.replace("hh", padLeft(date.hour.toString(), 2, "0"))
        text = text.replace("h", date.hour.toString())
        text = text.replace("ss", padLeft(date.second.toString(), 2, "0"))
        text = text.replace("s", date.second.toString())
        return text
    }
    var percent = false
    if (code.endsWith("%")) {
        percent = true
        code = code[0..code.size - 1]
    }
    var thousands = false
    if (code.contains("#,##0")) {
        thousands = true
        code = code.replace("#,##0", "0")
    }
    var decimals: Int64 = 0
    if (code.contains(".")) {
        let dot = code.indexOf(".") ?? -1
        if (dot >= 0) {
            decimals = Int64(code.size - dot - 1)
        }
    }
    let scaled = if (percent) { absValue * 100.0 } else { absValue }
    let text = formatFixed(scaled, decimals)
    var withCommas = text
    if (thousands) {
        withCommas = addThousandSeparators(text)
    }
    let suffix = if (percent) { "%" } else { "" }
    if (negative) {
        "-" + withCommas + suffix
    } else {
        withCommas + suffix
    }
}

private func padLeft(text: String, width: Int64, fill: String): String {
    var out = text
    while (Int64(out.size) < width) {
        out = fill + out
    }
    out
}

internal func formatFixed(value: Float64, decimals: Int64): String {
    if (decimals <= 0) {
        return formatNumber(floor(value + 0.5))
    }
    let factor = pow(10.0, Float64(decimals))
    let rounded = floor(value * factor + 0.5) / factor
    var text = formatNumber(rounded)
    let dot = text.indexOf(".") ?? -1
    if (dot < 0) {
        text += "."
        for (_ in 0..decimals) {
            text += "0"
        }
        return text
    }
    let current = Int64(text.size - dot - 1)
    if (current < decimals) {
        for (_ in 0..(decimals - current)) {
            text += "0"
        }
    } else if (current > decimals) {
        text = text[0..Int64(dot + decimals + 1)]
    }
    text
}

internal func addThousandSeparators(text: String): String {
    let dot = text.indexOf(".") ?? -1
    let intPart = if (dot < 0) { text } else { text[0..dot] }
    let fracPart = if (dot < 0) { "" } else { text[dot..] }
    let out = StringGenerator()
    let n = Int64(intPart.size)
    for (i in 0..n) {
        out.append<String>(intPart[i..i + 1])
        let remaining = n - i - 1
        if (remaining > 0 && remaining % 3 == 0) {
            out.append<String>(",")
        }
    }
    out.toString() + fracPart
}

internal func fnValue(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    match (scalarize(value)) {
        case Number(v) => CalcValue.Number(v)
        case Boolean(v) => CalcValue.Number(if (v) { 1.0 } else { 0.0 })
        case Empty => CalcValue.Number(0.0)
        case Text(text) =>
            var body = text.trimAscii().replace(",", "")
            var percent = false
            if (body.endsWith("%")) {
                percent = true
                body = body[0..body.size - 1]
            }
            match (parseNumberText(body)) {
                case Some(v) => CalcValue.Number(if (percent) { v / 100.0 } else { v })
                case None => CalcValue.Error(CalcError.Value)
            }
        case _ => CalcValue.Error(CalcError.Value)
    }
}

// ---------------------------------------------------------------- 日期

internal func fnDate(ev: Evaluator, args: Array<Expr>): CalcValue {
    let yearValue = ev.arg(args, 0)
    let monthValue = ev.arg(args, 1)
    let dayValue = ev.arg(args, 2)
    match (firstError([yearValue, monthValue, dayValue])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let year = match (calcToNumber(scalarize(yearValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let month = match (calcToNumber(scalarize(monthValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let day = match (calcToNumber(scalarize(dayValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (year < 0 || year > 9999) {
        return CalcValue.Error(CalcError.Num)
    }
    // 月份溢出：Excel 把 13 月算作次年 1 月
    let totalMonths = year * 12 + (month - 1)
    var normalizedYear = totalMonths / 12
    var normalizedMonth = totalMonths % 12
    if (normalizedMonth < 0) {
        normalizedMonth += 12
        normalizedYear--
    }
    normalizedMonth++
    if (normalizedYear < 1) {
        return CalcValue.Error(CalcError.Num)
    }
    let serial = excelSerialDays(normalizedYear, normalizedMonth, 1, ev.resolver.date1904())
    CalcValue.Number(Float64(serial + day - 1))
}

internal func fnDatePart(ev: Evaluator, args: Array<Expr>, part: String): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let serial = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let date = match (dateTimeFromSerial(serial, ev.resolver.date1904())) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    match (part) {
        case "year" => CalcValue.Number(Float64(date.year))
        case "month" => CalcValue.Number(Float64(date.month.toInteger()))
        case "day" => CalcValue.Number(Float64(date.dayOfMonth))
        case "hour" => CalcValue.Number(Float64(date.hour))
        case "minute" => CalcValue.Number(Float64(date.minute))
        case _ => CalcValue.Number(Float64(date.second))
    }
}
