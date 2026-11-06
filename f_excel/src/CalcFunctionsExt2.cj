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
import std.convert.*
import std.math.*
import std.time.DateTime
import fountain::f_base.StringGenerator

// ---------------------------------------------------------------- 数学扩展

internal func fnSumProduct(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grids = ArrayList<Array<Array<CalcValue>>>()
    var rows: Int64 = -1
    var cols: Int64 = -1
    for (i in 0..args.size) {
        let grid = gridOf(ev.arg(args, i))
        if (rows < 0) {
            rows = grid.size
            cols = if (grid.size > 0) { grid[0].size } else { 0 }
        } else if (Int64(grid.size) != rows || (grid.size > 0 && Int64(grid[0].size) != cols)) {
            return CalcValue.Error(CalcError.Value)
        }
        grids.add(grid)
    }
    var total = 0.0
    for (r in 0..rows) {
        for (c in 0..cols) {
            var product = 1.0
            for (grid in grids) {
                let value = grid[r][c]
                match (value) {
                    case Error(e) => return CalcValue.Error(e)
                    case Number(v) => product *= v
                    case _ => product *= 0.0
                }
            }
            total += product
        }
    }
    CalcValue.Number(total)
}

internal func fnCeilingFloor(ev: Evaluator, args: Array<Expr>, up: Bool): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    var significance = 1.0
    if (args.size > 1) {
        significance = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (significance == 0.0) {
        return CalcValue.Number(0.0)
    }
    if (significance < 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let quotient = number / significance
    let rounded = if (up) { ceil(quotient) } else { floor(quotient) }
    CalcValue.Number(rounded * significance)
}

internal func fnMround(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let multiple = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (multiple == 0.0) {
        return CalcValue.Number(0.0)
    }
    if (number * multiple < 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let quotient = number / multiple
    let rounded = if (quotient >= 0.0) { floor(quotient + 0.5) } else { ceil(quotient - 0.5) }
    CalcValue.Number(rounded * multiple)
}

internal func fnRand(ev: Evaluator, args: Array<Expr>): CalcValue {
    CalcValue.Number(ev.nextRandom())
}

internal func fnRandBetween(ev: Evaluator, args: Array<Expr>): CalcValue {
    let bottom = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let top = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (bottom > top) {
        return CalcValue.Error(CalcError.Num)
    }
    let span = top - bottom + 1
    CalcValue.Number(Float64(bottom + Int64(ev.nextRandom() * Float64(span))))
}

internal func fnLogBase(ev: Evaluator, args: Array<Expr>, fixedBase: Float64): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    var base = fixedBase
    if (fixedBase < 0.0 && args.size > 1) {
        base = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (number <= 0.0 || base <= 0.0 || base == 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(logBase(number, base))
}

internal func fnExp(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    CalcValue.Number(exp(number))
}

internal func fnPi(ev: Evaluator, args: Array<Expr>): CalcValue {
    CalcValue.Number(3.141592653589793)
}

internal func fnTrig(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    match (kind) {
        case "sin" => CalcValue.Number(sin(number))
        case "cos" => CalcValue.Number(cos(number))
        case "tan" => CalcValue.Number(tan(number))
        case "degrees" => CalcValue.Number(number * 180.0 / 3.141592653589793)
        case _ => CalcValue.Number(number * 3.141592653589793 / 180.0)
    }
}

internal func fnGcdLcm(ev: Evaluator, args: Array<Expr>, gcdMode: Bool): CalcValue {
    var result: Int64 = 0
    var first = true
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            var n = Int64(v)
            if (n < 0) {
                return CalcValue.Error(CalcError.Num)
            }
            if (gcdMode) {
                result = if (first) { n } else { gcd(result, n) }
                first = false
            } else {
                result = if (first) { n } else { result / gcd(result, n) * n }
                first = false
            }
        }
    }
    CalcValue.Number(Float64(result))
}

private func gcd(a: Int64, b: Int64): Int64 {
    var x = if (a < 0) { -a } else { a }
    var y = if (b < 0) { -b } else { b }
    while (y != 0) {
        let t = x % y
        x = y
        y = t
    }
    x
}

internal func fnFact(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (number < 0 || number > 170) {
        return CalcValue.Error(CalcError.Num)
    }
    var result = 1.0
    var i: Int64 = 2
    while (i <= number) {
        result *= Float64(i)
        i++
    }
    CalcValue.Number(result)
}

// ---------------------------------------------------------------- 日期扩展

private func isLeapYear(year: Int64): Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

private func daysInMonth(year: Int64, month: Int64): Int64 {
    match (month) {
        case 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
        case 4 | 6 | 9 | 11 => 30
        case 2 => if (isLeapYear(year)) { 29 } else { 28 }
        case _ => 30
    }
}

private func datePartsOf(ev: Evaluator, serial: Float64): ?DateTime {
    dateTimeFromSerial(serial, ev.resolver.date1904())
}

internal func fnDateValue(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0))).trimAscii()
    let normalized = text.replace("/", "-")
    let parts = normalized.split("-")
    if (parts.size < 3) {
        return CalcValue.Error(CalcError.Value)
    }
    let year = try {
        Int64.parse(parts[0])
    } catch (_: Exception) {
        return CalcValue.Error(CalcError.Value)
    }
    let month = try {
        Int64.parse(parts[1])
    } catch (_: Exception) {
        return CalcValue.Error(CalcError.Value)
    }
    let day = try {
        Int64.parse(parts[2])
    } catch (_: Exception) {
        return CalcValue.Error(CalcError.Value)
    }
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
        return CalcValue.Error(CalcError.Value)
    }
    CalcValue.Number(Float64(excelSerialDays(year, month, day, ev.resolver.date1904())))
}

internal func fnTimeValue(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0))).trimAscii()
    let parts = text.split(":")
    if (parts.size < 2) {
        return CalcValue.Error(CalcError.Value)
    }
    let hour = try {
        Int64.parse(parts[0])
    } catch (_: Exception) {
        return CalcValue.Error(CalcError.Value)
    }
    let minute = try {
        Int64.parse(parts[1])
    } catch (_: Exception) {
        return CalcValue.Error(CalcError.Value)
    }
    var second: Int64 = 0
    if (parts.size > 2) {
        second = try {
            Int64.parse(parts[2])
        } catch (_: Exception) {
            0
        }
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
        return CalcValue.Error(CalcError.Value)
    }
    CalcValue.Number(Float64(hour * 3600 + minute * 60 + second) / 86400.0)
}

private func addMonthsToSerial(ev: Evaluator, serial: Float64, months: Int64, lastDay: Bool): ?Float64 {
    let date = match (datePartsOf(ev, serial)) {
        case Some(v) => v
        case None => return None<Float64>
    }
    let totalMonths = date.year * 12 + (date.month.toInteger() - 1) + months
    var year = totalMonths / 12
    var month = totalMonths % 12
    if (month < 0) {
        month += 12
        year--
    }
    month++
    if (year < 1900 || year > 9999) {
        return None<Float64>
    }
    let maxDay = daysInMonth(year, month)
    var day = date.dayOfMonth
    if (lastDay || day > maxDay) {
        day = maxDay
    }
    let days = excelSerialDays(year, month, day, ev.resolver.date1904())
    let seconds = date.hour * 3600 + date.minute * 60 + date.second
    Some(Float64(days) + Float64(seconds) / 86400.0)
}

internal func fnEdate(ev: Evaluator, args: Array<Expr>, endOfMonth: Bool): CalcValue {
    let serial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let months = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    match (addMonthsToSerial(ev, serial, months, endOfMonth)) {
        case Some(v) => CalcValue.Number(floor(v))
        case None => CalcValue.Error(CalcError.Num)
    }
}

internal func fnWeekday(ev: Evaluator, args: Array<Expr>): CalcValue {
    let serial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    var kind: Int64 = 1
    if (args.size > 1) {
        kind = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    let date = match (datePartsOf(ev, serial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    // 0 = Sunday
    let sundayBased = Int64(date.dayOfWeek.toInteger())
    let result = match (kind) {
        case 1 => sundayBased + 1
        case 2 => if (sundayBased == 0) { 7 } else { sundayBased }
        case 3 => if (sundayBased == 0) { 6 } else { sundayBased - 1 }
        case _ => sundayBased + 1
    }
    CalcValue.Number(Float64(result))
}

internal func fnWeeknum(ev: Evaluator, args: Array<Expr>): CalcValue {
    let serial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let date = match (datePartsOf(ev, serial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    let jan1 = DateTime.ofUTC(
        year: date.year,
        month: 1,
        dayOfMonth: 1,
        hour: 0,
        minute: 0,
        second: 0,
        nanosecond: 0
    )
    let jan1Weekday = Int64(jan1.dayOfWeek.toInteger())
    let dayOfYear = date.dayOfYear
    let week = (dayOfYear - 1 + jan1Weekday) / 7 + 1
    CalcValue.Number(Float64(week))
}

internal func fnDatedif(ev: Evaluator, args: Array<Expr>): CalcValue {
    let startSerial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let endSerial = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let unit = calcToText(scalarize(ev.arg(args, 2))).toAsciiUpper()
    if (endSerial < startSerial) {
        return CalcValue.Error(CalcError.Num)
    }
    let start = match (datePartsOf(ev, startSerial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    let finish = match (datePartsOf(ev, endSerial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    let startDays = Int64(floor(startSerial))
    let endDays = Int64(floor(endSerial))
    match (unit) {
        case "D" => CalcValue.Number(Float64(endDays - startDays))
        case "M" =>
            var months = (finish.year - start.year) * 12 + (finish.month.toInteger() - start.month.toInteger())
            if (finish.dayOfMonth < start.dayOfMonth) {
                months--
            }
            CalcValue.Number(Float64(months))
        case "Y" =>
            var years = finish.year - start.year
            if (finish.month.toInteger() < start.month.toInteger() ||
                (finish.month.toInteger() == start.month.toInteger() && finish.dayOfMonth < start.dayOfMonth)) {
                years--
            }
            CalcValue.Number(Float64(years))
        case "MD" =>
            var day = finish.dayOfMonth - start.dayOfMonth
            if (day < 0) {
                var month = finish.month.toInteger() - 1
                var year = finish.year
                if (month < 1) {
                    month = 12
                    year--
                }
                day += daysInMonth(year, month)
            }
            CalcValue.Number(Float64(day))
        case "YM" =>
            var months = finish.month.toInteger() - start.month.toInteger()
            if (months < 0) {
                months += 12
            }
            if (finish.dayOfMonth < start.dayOfMonth) {
                months--
                if (months < 0) {
                    months += 12
                }
            }
            CalcValue.Number(Float64(months))
        case _ =>
            let anchorYear = finish.year
            var anchorMonth = start.month.toInteger()
            let anchorDay = if (start.dayOfMonth > daysInMonth(anchorYear, anchorMonth)) {
                daysInMonth(anchorYear, anchorMonth)
            } else {
                start.dayOfMonth
            }
            let anchor = DateTime.ofUTC(
                year: anchorYear,
                month: anchorMonth,
                dayOfMonth: anchorDay,
                hour: 0,
                minute: 0,
                second: 0,
                nanosecond: 0
            )
            let delta = finish.toUnixTimeStamp().toNanoseconds() - anchor.toUnixTimeStamp().toNanoseconds()
            CalcValue.Number(Float64(delta / 86_400_000_000_000))
    }
}

internal func fnDays(ev: Evaluator, args: Array<Expr>): CalcValue {
    let endSerial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let startSerial = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    CalcValue.Number(floor(endSerial) - floor(startSerial))
}

internal func fnDays360(ev: Evaluator, args: Array<Expr>): CalcValue {
    let startSerial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let endSerial = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let start = match (datePartsOf(ev, startSerial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    let finish = match (datePartsOf(ev, endSerial)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    var startDay = start.dayOfMonth
    var endDay = finish.dayOfMonth
    if (startDay == 31) {
        startDay = 30
    }
    if (endDay == 31) {
        endDay = 30
    }
    let days = (finish.year - start.year) * 360 +
        (finish.month.toInteger() - start.month.toInteger()) * 30 +
        (endDay - startDay)
    CalcValue.Number(Float64(days))
}

internal func holidaySet(ev: Evaluator, args: Array<Expr>): ArrayList<Int64> {
    let list = ArrayList<Int64>()
    if (args.size > 2) {
        let (nums, _) = numbersOf(ev, args, 2)
        for (v in nums) {
            list.add(Int64(floor(v)))
        }
    }
    list
}

internal func fnNetworkdays(ev: Evaluator, args: Array<Expr>): CalcValue {
    let startSerial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(floor(v))
        case None => return CalcValue.Error(CalcError.Value)
    }
    let endSerial = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(floor(v))
        case None => return CalcValue.Error(CalcError.Value)
    }
    let holidays = holidaySet(ev, args)
    let lower = if (startSerial < endSerial) { startSerial } else { endSerial }
    let upper = if (startSerial < endSerial) { endSerial } else { startSerial }
    var count: Int64 = 0
    var day = lower
    while (day <= upper) {
        match (datePartsOf(ev, Float64(day))) {
            case Some(date) =>
                let weekday = date.dayOfWeek.toInteger()
                if (weekday != 0 && weekday != 6 && !holidays.contains(day)) {
                    count++
                }
            case None => ()
        }
        day++
    }
    if (startSerial > endSerial) {
        count = -count
    }
    CalcValue.Number(Float64(count))
}

internal func fnWorkday(ev: Evaluator, args: Array<Expr>): CalcValue {
    let startSerial = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(floor(v))
        case None => return CalcValue.Error(CalcError.Value)
    }
    let days = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let holidays = holidaySet(ev, args)
    var current = startSerial
    var remaining = days
    let step: Int64 = if (days >= 0) { 1 } else { -1 }
    while (remaining != 0) {
        current += step
        match (datePartsOf(ev, Float64(current))) {
            case Some(date) =>
                let weekday = date.dayOfWeek.toInteger()
                if (weekday != 0 && weekday != 6 && !holidays.contains(current)) {
                    remaining -= step
                }
            case None => ()
        }
    }
    CalcValue.Number(Float64(current))
}

// ---------------------------------------------------------------- 财务

internal func numberArg(ev: Evaluator, args: Array<Expr>, index: Int64, fallback: Float64): ?Float64 {
    if (index >= args.size) {
        return Some(fallback)
    }
    calcToNumber(scalarize(ev.arg(args, index)))
}

internal func fnPmt(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    let nperOption = numberArg(ev, args, 1, 0.0)
    if (nperOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let nper = nperOption.getOrThrow()
    let pvOption = numberArg(ev, args, 2, 0.0)
    if (pvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pv = pvOption.getOrThrow()
    let fvOption = numberArg(ev, args, 3, 0.0)
    if (fvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let fv = fvOption.getOrThrow()
    let kindOption = numberArg(ev, args, 4, 0.0)
    if (kindOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let kind = kindOption.getOrThrow()
    if (nper == 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (rate == 0.0) {
        return CalcValue.Number(-(pv + fv) / nper)
    }
    let factor = pow(1.0 + rate, nper)
    CalcValue.Number(-(rate * (fv + pv * factor)) / ((factor - 1.0) * (1.0 + rate * kind)))
}

internal func fnFv(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    let nperOption = numberArg(ev, args, 1, 0.0)
    if (nperOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let nper = nperOption.getOrThrow()
    let pmtOption = numberArg(ev, args, 2, 0.0)
    if (pmtOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pmt = pmtOption.getOrThrow()
    let pvOption = numberArg(ev, args, 3, 0.0)
    if (pvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pv = pvOption.getOrThrow()
    let kindOption = numberArg(ev, args, 4, 0.0)
    if (kindOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let kind = kindOption.getOrThrow()
    if (rate == 0.0) {
        return CalcValue.Number(-(pv + pmt * nper))
    }
    let factor = pow(1.0 + rate, nper)
    CalcValue.Number(-(pv * factor + pmt * (1.0 + rate * kind) * (factor - 1.0) / rate))
}

internal func fnPv(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    let nperOption = numberArg(ev, args, 1, 0.0)
    if (nperOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let nper = nperOption.getOrThrow()
    let pmtOption = numberArg(ev, args, 2, 0.0)
    if (pmtOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pmt = pmtOption.getOrThrow()
    let fvOption = numberArg(ev, args, 3, 0.0)
    if (fvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let fv = fvOption.getOrThrow()
    let kindOption = numberArg(ev, args, 4, 0.0)
    if (kindOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let kind = kindOption.getOrThrow()
    if (rate == 0.0) {
        return CalcValue.Number(-(fv + pmt * nper))
    }
    let factor = pow(1.0 + rate, nper)
    CalcValue.Number(-(fv + pmt * (1.0 + rate * kind) * (factor - 1.0) / rate) / factor)
}

internal func fnNper(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    let pmtOption = numberArg(ev, args, 1, 0.0)
    if (pmtOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pmt = pmtOption.getOrThrow()
    let pvOption = numberArg(ev, args, 2, 0.0)
    if (pvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pv = pvOption.getOrThrow()
    let fvOption = numberArg(ev, args, 3, 0.0)
    if (fvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let fv = fvOption.getOrThrow()
    let kindOption = numberArg(ev, args, 4, 0.0)
    if (kindOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let kind = kindOption.getOrThrow()
    if (rate == 0.0) {
        if (pmt == 0.0) {
            return CalcValue.Error(CalcError.DivZero)
        }
        return CalcValue.Number(-(pv + fv) / pmt)
    }
    let numerator = pmt * (1.0 + rate * kind) - fv * rate
    let denominator = pv * rate + pmt * (1.0 + rate * kind)
    let ratio = numerator / denominator
    if (ratio <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(log(ratio) / log(1.0 + rate))
}

internal func fnSln(ev: Evaluator, args: Array<Expr>): CalcValue {
    let costOption = numberArg(ev, args, 0, 0.0)
    if (costOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let cost = costOption.getOrThrow()
    let salvageOption = numberArg(ev, args, 1, 0.0)
    if (salvageOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let salvage = salvageOption.getOrThrow()
    let lifeOption = numberArg(ev, args, 2, 0.0)
    if (lifeOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let life = lifeOption.getOrThrow()
    if (life == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number((cost - salvage) / life)
}

internal func fnNpv(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    var total = 0.0
    var index: Int64 = 1
    for (i in 1..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            total += v / pow(1.0 + rate, Float64(index))
            index++
        }
    }
    CalcValue.Number(total)
}

internal func fnIpmt(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rateOption = numberArg(ev, args, 0, 0.0)
    if (rateOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let rate = rateOption.getOrThrow()
    let perOption = numberArg(ev, args, 1, 0.0)
    if (perOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let per = perOption.getOrThrow()
    let nperOption = numberArg(ev, args, 2, 0.0)
    if (nperOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let nper = nperOption.getOrThrow()
    let pvOption = numberArg(ev, args, 3, 0.0)
    if (pvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let pv = pvOption.getOrThrow()
    let fvOption = numberArg(ev, args, 4, 0.0)
    if (fvOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let fv = fvOption.getOrThrow()
    let kindOption = numberArg(ev, args, 5, 0.0)
    if (kindOption.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let kind = kindOption.getOrThrow()
    if (per < 1.0 || per > nper) {
        return CalcValue.Error(CalcError.Num)
    }
    let pmt = match (fnPmt(ev, [Expr.Lit(CalcValue.Number(rate)), Expr.Lit(CalcValue.Number(nper)),
            Expr.Lit(CalcValue.Number(pv)), Expr.Lit(CalcValue.Number(fv)),
            Expr.Lit(CalcValue.Number(kind))])) {
        case Number(v) => v
        case _ => return CalcValue.Error(CalcError.Num)
    }
    let balance = if (rate == 0.0) {
        pv + pmt * (per - 1.0)
    } else {
        pv * pow(1.0 + rate, per - 1.0) + pmt * (1.0 + rate * kind) *
            (pow(1.0 + rate, per - 1.0) - 1.0) / rate
    }
    CalcValue.Number(-balance * rate)
}

internal func fnPpmt(ev: Evaluator, args: Array<Expr>): CalcValue {
    // PPMT 的实参是 (rate, per, nper, pv, ...)，PMT 需要 (rate, nper, pv, ...)
    let rate = numberArg(ev, args, 0, 0.0) ?? 0.0
    let nper = numberArg(ev, args, 2, 0.0) ?? 0.0
    let pv = numberArg(ev, args, 3, 0.0) ?? 0.0
    let fv = numberArg(ev, args, 4, 0.0) ?? 0.0
    let kind = numberArg(ev, args, 5, 0.0) ?? 0.0
    let pmt = match (fnPmt(ev, [Expr.Lit(CalcValue.Number(rate)), Expr.Lit(CalcValue.Number(nper)),
            Expr.Lit(CalcValue.Number(pv)), Expr.Lit(CalcValue.Number(fv)),
            Expr.Lit(CalcValue.Number(kind))])) {
        case Number(v) => v
        case _ => return CalcValue.Error(CalcError.Num)
    }
    let interest = match (fnIpmt(ev, args)) {
        case Number(v) => v
        case _ => return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(pmt - interest)
}

// ---------------------------------------------------------------- 信息扩展

internal func fnIsErr(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (scalarize(ev.arg(args, 0))) {
        case Error(e) => CalcValue.Boolean(e != CalcError.NotAvailable)
        case _ => CalcValue.Boolean(false)
    }
}

internal func fnNa(ev: Evaluator, args: Array<Expr>): CalcValue {
    CalcValue.Error(CalcError.NotAvailable)
}

internal func fnType(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (scalarize(ev.arg(args, 0))) {
        case Number(_) => CalcValue.Number(1.0)
        case Empty => CalcValue.Number(1.0)
        case Text(_) => CalcValue.Number(2.0)
        case Boolean(_) => CalcValue.Number(4.0)
        case Error(_) => CalcValue.Number(16.0)
        case ArrayValue(_) => CalcValue.Number(64.0)
    }
}

internal func fnErrorType(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (scalarize(ev.arg(args, 0))) {
        case Error(e) => match (e) {
            case Null => CalcValue.Number(1.0)
            case DivZero => CalcValue.Number(2.0)
            case Value => CalcValue.Number(3.0)
            case Ref => CalcValue.Number(4.0)
            case Name => CalcValue.Number(5.0)
            case Num => CalcValue.Number(6.0)
            case NotAvailable => CalcValue.Number(7.0)
            case _ => CalcValue.Error(CalcError.NotAvailable)
        }
        case _ => CalcValue.Error(CalcError.NotAvailable)
    }
}
