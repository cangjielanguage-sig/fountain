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
import std.time.DateTime
import fountain::f_base.StringGenerator

// ---------------------------------------------------------------- 动态数组（续）

private func minI(a: Int64, b: Int64): Int64 {
    if (a < b) { a } else { b }
}

private func maxI(a: Int64, b: Int64): Int64 {
    if (a > b) { a } else { b }
}

internal func fnSortBy(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let keys = gridOf(ev.arg(args, 1))
    if (grid.size == 0 || keys.size != grid.size) {
        return CalcValue.Error(CalcError.Value)
    }
    var order: Int64 = 1
    if (args.size > 2) {
        order = Int64(numberArg(ev, args, 2, 1.0) ?? 1.0)
    }
    let rows = ArrayList<Array<CalcValue>>()
    let keyValues = ArrayList<CalcValue>()
    for (i in 0..grid.size) {
        rows.add(grid[i])
        keyValues.add(if (keys[i].size > 0) { keys[i][0] } else { CalcValue.Empty })
    }
    for (i in 1..rows.size) {
        let key = rows[i]
        let keyValue = keyValues[i]
        var j = i - 1
        while (j >= 0) {
            let cmp = compareCalc(keyValues[j], keyValue) ?? 0
            let shouldMove = if (order > 0) { cmp > 0 } else { cmp < 0 }
            if (!shouldMove) {
                break
            }
            rows[j + 1] = rows[j]
            keyValues[j + 1] = keyValues[j]
            j--
        }
        rows[j + 1] = key
        keyValues[j + 1] = keyValue
    }
    CalcValue.ArrayValue(rows.toArray())
}

internal func fnTakeDrop(ev: Evaluator, args: Array<Expr>, take: Bool): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let rows = Int64(numberArg(ev, args, 1, Float64(grid.size)) ?? Float64(grid.size))
    var cols: Int64 = if (grid.size > 0) { grid[0].size } else { 0 }
    let hasCols = args.size > 2
    if (hasCols) {
        cols = Int64(numberArg(ev, args, 2, Float64(cols)) ?? Float64(cols))
    }
    let totalRows = Int64(grid.size)
    let totalCols = if (grid.size > 0) { grid[0].size } else { 0 }
    var rowStart: Int64 = 0
    var rowEnd = totalRows
    if (take) {
        rowEnd = if (rows >= 0) { minI(rows, totalRows) } else { maxI(totalRows + rows, 0) }
        if (rows < 0) {
            rowStart = maxI(totalRows + rows, 0)
            rowEnd = totalRows
        }
    } else {
        if (rows >= 0) {
            rowStart = minI(rows, totalRows)
        } else {
            rowEnd = maxI(totalRows + rows, 0)
        }
    }
    var colStart: Int64 = 0
    var colEnd = totalCols
    if (hasCols) {
        if (take) {
            if (cols >= 0) {
                colEnd = minI(cols, totalCols)
            } else {
                colStart = maxI(totalCols + cols, 0)
                colEnd = totalCols
            }
        } else {
            if (cols >= 0) {
                colStart = minI(cols, totalCols)
            } else {
                colEnd = maxI(totalCols + cols, 0)
            }
        }
    }
    if (rowStart >= rowEnd || colStart >= colEnd) {
        return CalcValue.Error(CalcError.Calc)
    }
    let out = ArrayList<Array<CalcValue>>()
    for (r in rowStart..rowEnd) {
        let line = ArrayList<CalcValue>()
        for (c in colStart..colEnd) {
            line.add(if (c < grid[r].size) { grid[r][c] } else { CalcValue.Empty })
        }
        out.add(line.toArray())
    }
    CalcValue.ArrayValue(out.toArray())
}

internal func fnChooseRowsCols(ev: Evaluator, args: Array<Expr>, rowsMode: Bool): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let out = ArrayList<Array<CalcValue>>()
    if (rowsMode) {
        for (i in 1..args.size) {
            let index = Int64(numberArg(ev, args, i, 0.0) ?? 0.0)
            let actual = if (index < 0) { Int64(grid.size) + index } else { index - 1 }
            if (actual < 0 || actual >= grid.size) {
                return CalcValue.Error(CalcError.Ref)
            }
            out.add(grid[actual])
        }
    } else {
        let indices = ArrayList<Int64>()
        for (i in 1..args.size) {
            let index = Int64(numberArg(ev, args, i, 0.0) ?? 0.0)
            let actual = if (index < 0) { (if (grid.size > 0) { grid[0].size } else { 0 }) + index } else { index - 1 }
            indices.add(actual)
        }
        for (row in grid) {
            let line = ArrayList<CalcValue>()
            for (index in indices) {
                if (index < 0 || index >= row.size) {
                    return CalcValue.Error(CalcError.Ref)
                }
                line.add(row[index])
            }
            out.add(line.toArray())
        }
    }
    CalcValue.ArrayValue(out.toArray())
}

internal func fnExpand(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let rows = Int64(numberArg(ev, args, 1, Float64(grid.size)) ?? Float64(grid.size))
    var cols: Int64 = if (grid.size > 0) { grid[0].size } else { 0 }
    if (args.size > 2) {
        cols = Int64(numberArg(ev, args, 2, Float64(cols)) ?? Float64(cols))
    }
    var pad = CalcValue.Error(CalcError.NotAvailable)
    if (args.size > 3) {
        pad = scalarize(ev.arg(args, 3))
    }
    if (rows < Int64(grid.size) || cols < (if (grid.size > 0) { grid[0].size } else { 0 })) {
        return CalcValue.Error(CalcError.Value)
    }
    let out = ArrayList<Array<CalcValue>>()
    for (r in 0..rows) {
        let line = ArrayList<CalcValue>()
        for (c in 0..cols) {
            if (r < grid.size && c < grid[r].size) {
                line.add(grid[r][c])
            } else {
                line.add(pad)
            }
        }
        out.add(line.toArray())
    }
    CalcValue.ArrayValue(out.toArray())
}

internal func fnStack(ev: Evaluator, args: Array<Expr>, vertical: Bool): CalcValue {
    let out = ArrayList<Array<CalcValue>>()
    if (vertical) {
        for (i in 0..args.size) {
            for (row in gridOf(ev.arg(args, i))) {
                out.add(row)
            }
        }
    } else {
        var height: Int64 = 0
        for (i in 0..args.size) {
            let grid = gridOf(ev.arg(args, i))
            if (Int64(grid.size) > height) {
                height = Int64(grid.size)
            }
        }
        for (r in 0..height) {
            let line = ArrayList<CalcValue>()
            for (i in 0..args.size) {
                let grid = gridOf(ev.arg(args, i))
                if (r < grid.size) {
                    for (item in grid[r]) {
                        line.add(item)
                    }
                }
            }
            out.add(line.toArray())
        }
    }
    CalcValue.ArrayValue(out.toArray())
}

internal func fnToLine(ev: Evaluator, args: Array<Expr>, asColumn: Bool): CalcValue {
    let values = flattenValues(ev.arg(args, 0))
    let rows = ArrayList<Array<CalcValue>>()
    if (asColumn) {
        for (item in values) {
            rows.add([item])
        }
    } else {
        rows.add(values.toArray())
    }
    CalcValue.ArrayValue(rows.toArray())
}

internal func fnWrap(ev: Evaluator, args: Array<Expr>, byRows: Bool): CalcValue {
    let values = flattenValues(ev.arg(args, 0))
    let wrap = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    if (wrap < 1) {
        return CalcValue.Error(CalcError.Num)
    }
    let out = ArrayList<Array<CalcValue>>()
    if (byRows) {
        var i: Int64 = 0
        while (i < values.size) {
            let line = ArrayList<CalcValue>()
            var c: Int64 = 0
            while (c < wrap && i < values.size) {
                line.add(values[i])
                i++
                c++
            }
            out.add(line.toArray())
        }
    } else {
        let rowsCount = (values.size + wrap - 1) / wrap
        for (_ in 0..rowsCount) {
            out.add(Array<CalcValue>())
        }
        for (i in 0..values.size) {
            let r = i % rowsCount
            let current = ArrayList<CalcValue>()
            for (item in out[r]) {
                current.add(item)
            }
            current.add(values[i])
            out[r] = current.toArray()
        }
    }
    CalcValue.ArrayValue(out.toArray())
}

internal func fnAddress(ev: Evaluator, args: Array<Expr>): CalcValue {
    let row = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let col = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    var absNum: Int64 = 1
    if (args.size > 2) {
        absNum = Int64(numberArg(ev, args, 2, 1.0) ?? 1.0)
    }
    if (row < 1 || col < 1 || row > EXCEL_MAX_ROW || col > EXCEL_MAX_COL) {
        return CalcValue.Error(CalcError.Value)
    }
    let colAbs = absNum == 1 || absNum == 3
    let rowAbs = absNum == 1 || absNum == 2
    let text = CellRef(row, col, rowAbs: rowAbs, colAbs: colAbs).toA1()
    if (args.size > 4) {
        let sheet = calcToText(scalarize(ev.arg(args, 4)))
        return CalcValue.Text("'${sheet}'!${text}")
    }
    CalcValue.Text(text)
}

internal func fnAreas(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (args[0]) {
        case RangeExpr(_, _, _) => CalcValue.Number(1.0)
        case Ref(_, _) => CalcValue.Number(1.0)
        case _ => CalcValue.Error(CalcError.Value)
    }
}

internal func fnHyperlink(ev: Evaluator, args: Array<Expr>): CalcValue {
    if (args.size > 1) {
        return CalcValue.Text(calcToText(scalarize(ev.arg(args, 1))))
    }
    CalcValue.Text(calcToText(scalarize(ev.arg(args, 0))))
}

internal func fnXMatch(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let values = flattenValues(ev.arg(args, 1))
    var mode: Int64 = 0
    if (args.size > 2) {
        mode = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
    }
    var best: Int64 = -1
    for (i in 0..values.size) {
        let cmp = compareCalc(values[i], lookup) ?? 0
        if (cmp == 0) {
            return CalcValue.Number(Float64(i + 1))
        }
        match (mode) {
            case -1 => if (cmp < 0) {
                best = i
            }
            case 1 => if (cmp > 0 && best < 0) {
                best = i
            }
            case _ => ()
        }
    }
    if (best >= 0) {
        return CalcValue.Number(Float64(best + 1))
    }
    CalcValue.Error(CalcError.NotAvailable)
}

// ---------------------------------------------------------------- 日期扩展

internal func fnTime(ev: Evaluator, args: Array<Expr>): CalcValue {
    let hour = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let minute = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    let second = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
    let total = hour * 3600 + minute * 60 + second
    if (total < 0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(Float64(total % 86400) / 86400.0)
}

internal func fnIsoWeeknum(ev: Evaluator, args: Array<Expr>): CalcValue {
    let serial = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let date = match (dateTimeFromSerial(serial, ev.resolver.date1904())) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    let jan4 = DateTime.ofUTC(
        year: date.year,
        month: 1,
        dayOfMonth: 4,
        hour: 0,
        minute: 0,
        second: 0,
        nanosecond: 0
    )
    let jan4Weekday = Int64(jan4.dayOfWeek.toInteger())
    let mondayOffset = if (jan4Weekday == 0) { 6 } else { jan4Weekday - 1 }
    let week1Monday = jan4.toUnixTimeStamp().toNanoseconds() / 86_400_000_000_000 - mondayOffset
    let dayNumber = date.toUnixTimeStamp().toNanoseconds() / 86_400_000_000_000
    CalcValue.Number(Float64((dayNumber - week1Monday) / 7 + 1))
}

internal func fnYearFrac(ev: Evaluator, args: Array<Expr>): CalcValue {
    let start = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let end = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var basis: Int64 = 0
    if (args.size > 2) {
        basis = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
    }
    let days = end - start
    let result = match (basis) {
        case 1 =>
            // 实际/实际：按起始年天数
            let date = dateTimeFromSerial(start, ev.resolver.date1904())
            let yearDays = match (date) {
                case Some(v) => if ((v.year % 4 == 0 && v.year % 100 != 0) || v.year % 400 == 0) { 366.0 } else { 365.0 }
                case None => 365.0
            }
            days / yearDays
        case 2 => days / 360.0
        case 3 => days / 365.0
        case 4 =>
            // 欧洲 30/360
            let s = dateTimeFromSerial(start, ev.resolver.date1904())
            let e = dateTimeFromSerial(end, ev.resolver.date1904())
            match ((s, e)) {
                case (Some(a), Some(b)) =>
                    var d1 = a.dayOfMonth
                    var d2 = b.dayOfMonth
                    if (d1 == 31) { d1 = 30 }
                    if (d2 == 31) { d2 = 30 }
                    (Float64((b.year - a.year) * 360 + (b.month.toInteger() - a.month.toInteger()) * 30 + (d2 - d1))) / 360.0
                case _ => days / 360.0
            }
        case _ =>
            // 美国 30/360（简化）
            let s = dateTimeFromSerial(start, ev.resolver.date1904())
            let e = dateTimeFromSerial(end, ev.resolver.date1904())
            match ((s, e)) {
                case (Some(a), Some(b)) =>
                    var d1 = a.dayOfMonth
                    var d2 = b.dayOfMonth
                    if (d1 == 31) { d1 = 30 }
                    if (d2 == 31) { d2 = 30 }
                    (Float64((b.year - a.year) * 360 + (b.month.toInteger() - a.month.toInteger()) * 30 + (d2 - d1))) / 360.0
                case _ => days / 360.0
            }
    }
    CalcValue.Number(result)
}

internal func fnNetworkdaysIntl(ev: Evaluator, args: Array<Expr>): CalcValue {
    // weekend 参数只支持 1（周六/周日）与 7（周五/周六）
    let start = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let end = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    var weekend: Int64 = 1
    if (args.size > 2) {
        weekend = Int64(numberArg(ev, args, 2, 1.0) ?? 1.0)
    }
    let holidays = holidaySet(ev, args)
    var count: Int64 = 0
    var day = minI(start, end)
    while (day <= maxI(start, end)) {
        match (dateTimeFromSerial(Float64(day), ev.resolver.date1904())) {
            case Some(date) =>
                let weekday = Int64(date.dayOfWeek.toInteger())
                let off = if (weekend == 7) { weekday == 5 || weekday == 6 } else { weekday == 0 || weekday == 6 }
                if (!off && !holidays.contains(day)) {
                    count++
                }
            case None => ()
        }
        day++
    }
    CalcValue.Number(Float64(count))
}

internal func fnWorkdayIntl(ev: Evaluator, args: Array<Expr>): CalcValue {
    let start = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let days = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    var weekend: Int64 = 1
    if (args.size > 2) {
        weekend = Int64(numberArg(ev, args, 2, 1.0) ?? 1.0)
    }
    let holidays = holidaySet(ev, args)
    var current = start
    var remaining = days
    let step: Int64 = if (days >= 0) { 1 } else { -1 }
    while (remaining != 0) {
        current += step
        match (dateTimeFromSerial(Float64(current), ev.resolver.date1904())) {
            case Some(date) =>
                let weekday = Int64(date.dayOfWeek.toInteger())
                let off = if (weekend == 7) { weekday == 5 || weekday == 6 } else { weekday == 0 || weekday == 6 }
                if (!off && !holidays.contains(current)) {
                    remaining -= step
                }
            case None => ()
        }
    }
    CalcValue.Number(Float64(current))
}

// ---------------------------------------------------------------- 财务扩展

internal func fnDb(ev: Evaluator, args: Array<Expr>): CalcValue {
    let cost = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let salvage = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let life = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let period = numberArg(ev, args, 3, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var month: Int64 = 12
    if (args.size > 4) {
        month = Int64(numberArg(ev, args, 4, 12.0) ?? 12.0)
    }
    if (cost <= 0.0 || life <= 0.0 || period < 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let rate = 1.0 - pow(salvage / cost, 1.0 / life)
    let rounded = floor(rate * 1000.0 + 0.5) / 1000.0
    if (period == 1.0) {
        return CalcValue.Number(cost * rounded * Float64(month) / 12.0)
    }
    var book = cost - cost * rounded * Float64(month) / 12.0
    var depreciation = 0.0
    var i: Int64 = 2
    while (Float64(i) <= period) {
        depreciation = book * rounded
        book -= depreciation
        i++
    }
    CalcValue.Number(depreciation)
}

internal func fnDdb(ev: Evaluator, args: Array<Expr>): CalcValue {
    let cost = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let salvage = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let life = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let period = numberArg(ev, args, 3, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var factor = 2.0
    if (args.size > 4) {
        factor = numberArg(ev, args, 4, 2.0) ?? 2.0
    }
    if (cost <= 0.0 || life <= 0.0 || period < 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var book = cost
    var depreciation = 0.0
    var i: Int64 = 1
    while (Float64(i) <= period) {
        depreciation = minD(book * factor / life, book - salvage)
        if (depreciation < 0.0) {
            depreciation = 0.0
        }
        book -= depreciation
        i++
    }
    CalcValue.Number(depreciation)
}

private func minD(a: Float64, b: Float64): Float64 {
    if (a < b) { a } else { b }
}

internal func fnSyd(ev: Evaluator, args: Array<Expr>): CalcValue {
    let cost = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let salvage = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let life = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let period = numberArg(ev, args, 3, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (life <= 0.0 || period < 1.0 || period > life) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number((cost - salvage) * (life - period + 1.0) * 2.0 / (life * (life + 1.0)))
}

internal func fnEffectNominal(ev: Evaluator, args: Array<Expr>, effect: Bool): CalcValue {
    let rate = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let periods = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    if (rate <= 0.0 || periods < 1) {
        return CalcValue.Error(CalcError.Num)
    }
    if (effect) {
        CalcValue.Number(pow(1.0 + rate / Float64(periods), Float64(periods)) - 1.0)
    } else {
        CalcValue.Number((pow(1.0 + rate, 1.0 / Float64(periods)) - 1.0) * Float64(periods))
    }
}

internal func fnFvSchedule(ev: Evaluator, args: Array<Expr>): CalcValue {
    let principal = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let (rates, error) = numbersOf(ev, args, 1)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var value = principal
    for (rate in rates) {
        value *= 1.0 + rate
    }
    CalcValue.Number(value)
}

internal func fnPduration(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rate = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let pv = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let fv = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (rate <= 0.0 || pv <= 0.0 || fv <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(log(fv / pv) / log(1.0 + rate))
}

internal func fnRri(ev: Evaluator, args: Array<Expr>): CalcValue {
    let nper = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let pv = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let fv = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (nper <= 0.0 || pv <= 0.0 || fv <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(pow(fv / pv, 1.0 / nper) - 1.0)
}

internal func fnIspmt(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rate = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let per = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let nper = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let pv = numberArg(ev, args, 3, 0.0) ?? return CalcValue.Error(CalcError.Value)
    CalcValue.Number(-pv * rate * (nper - per) / nper)
}

internal func fnCumPayment(ev: Evaluator, args: Array<Expr>, principal: Bool): CalcValue {
    let rate = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let nper = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    let pv = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let start = Int64(numberArg(ev, args, 3, 1.0) ?? 1.0)
    let end = Int64(numberArg(ev, args, 4, Float64(nper)) ?? Float64(nper))
    let kind = Int64(numberArg(ev, args, 5, 0.0) ?? 0.0)
    if (start < 1 || end > nper || start > end) {
        return CalcValue.Error(CalcError.Num)
    }
    let callArgs = [
        Expr.Lit(CalcValue.Number(rate)),
        Expr.Lit(CalcValue.Number(0.0)),
        Expr.Lit(CalcValue.Number(Float64(nper))),
        Expr.Lit(CalcValue.Number(pv)),
        Expr.Lit(CalcValue.Number(0.0)),
        Expr.Lit(CalcValue.Number(Float64(kind)))
    ]
    var total = 0.0
    var per = start
    while (per <= end) {
        callArgs[1] = Expr.Lit(CalcValue.Number(Float64(per)))
        let value = if (principal) { fnPpmt(ev, callArgs) } else { fnIpmt(ev, callArgs) }
        match (value) {
            case Number(v) => total += v
            case _ => return CalcValue.Error(CalcError.Num)
        }
        per++
    }
    CalcValue.Number(total)
}

internal func fnDollarDeFr(ev: Evaluator, args: Array<Expr>, decimal: Bool): CalcValue {
    let value = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let fraction = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    if (fraction <= 0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    let digits = Int64(log10(Float64(fraction))) + 1
    let scale = pow(10.0, Float64(digits))
    let integer = floor(value)
    let frac = value - integer
    if (decimal) {
        CalcValue.Number(integer + frac * scale / Float64(fraction))
    } else {
        CalcValue.Number(integer + frac * Float64(fraction) / scale)
    }
}

internal func fnIrr(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = numbersOf(ev, args, 0)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size < 2) {
        return CalcValue.Error(CalcError.Num)
    }
    var low = -0.9999
    var high = 10.0
    var fLow = npvAt(values, low)
    var fHigh = npvAt(values, high)
    if (fLow * fHigh > 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mid = 0.0
    for (_ in 0..200) {
        mid = (low + high) / 2.0
        let fMid = npvAt(values, mid)
        if (abs(fMid) < 1e-10) {
            return CalcValue.Number(mid)
        }
        if (fLow * fMid < 0.0) {
            high = mid
            fHigh = fMid
        } else {
            low = mid
            fLow = fMid
        }
    }
    CalcValue.Number(mid)
}

private func npvAt(values: ArrayList<Float64>, rate: Float64): Float64 {
    var total = 0.0
    for (i in 0..values.size) {
        total += values[i] / pow(1.0 + rate, Float64(i))
    }
    total
}

internal func fnRate(ev: Evaluator, args: Array<Expr>): CalcValue {
    let nper = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let pmt = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let pv = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let fv = numberArg(ev, args, 3, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let kind = numberArg(ev, args, 4, 0.0) ?? 0.0
    var low = -0.9999
    var high = 10.0
    var fLow = rateAt(low, nper, pmt, pv, fv, kind)
    var fHigh = rateAt(high, nper, pmt, pv, fv, kind)
    if (fLow * fHigh > 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mid = 0.0
    for (_ in 0..200) {
        mid = (low + high) / 2.0
        let fMid = rateAt(mid, nper, pmt, pv, fv, kind)
        if (abs(fMid) < 1e-10) {
            return CalcValue.Number(mid)
        }
        if (fLow * fMid < 0.0) {
            high = mid
            fHigh = fMid
        } else {
            low = mid
            fLow = fMid
        }
    }
    CalcValue.Number(mid)
}

private func rateAt(rate: Float64, nper: Float64, pmt: Float64, pv: Float64, fv: Float64, kind: Float64): Float64 {
    if (rate == 0.0) {
        return pv + pmt * nper + fv
    }
    let factor = pow(1.0 + rate, nper)
    fv + pv * factor + pmt * (1.0 + rate * kind) * (factor - 1.0) / rate
}

internal func fnMirr(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = numbersOf(ev, args, 0)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let finance = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let reinvest = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let n = values.size
    if (n < 2) {
        return CalcValue.Error(CalcError.DivZero)
    }
    var positive = 0.0
    var negative = 0.0
    for (i in 0..n) {
        if (values[i] > 0.0) {
            positive += values[i] * pow(1.0 + reinvest, Float64(n - 1 - i))
        } else {
            negative += values[i] / pow(1.0 + finance, Float64(i))
        }
    }
    if (negative == 0.0 || positive == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(pow(positive / -negative, 1.0 / Float64(n - 1)) - 1.0)
}
