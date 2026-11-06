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

import std.collection.{ArrayList, HashMap}
import std.math.*
import fountain::f_base.StringGenerator

// ---------------------------------------------------------------- 数据库

private func dbRows(ev: Evaluator, args: Array<Expr>): (Array<Array<CalcValue>>, Int64, ArrayList<Array<CalcValue>>, ?CalcError) {
    let grid = gridOf(ev.arg(args, 0))
    let criteria = gridOf(ev.arg(args, 2))
    if (grid.size == 0 || criteria.size == 0) {
        return (grid, -1, ArrayList<Array<CalcValue>>(), Some(CalcError.Value))
    }
    let fieldValue = scalarize(ev.arg(args, 1))
    var fieldIndex: Int64 = -1
    match (fieldValue) {
        case Number(v) =>
            fieldIndex = Int64(v) - 1
        case Text(name) =>
            for (i in 0..grid[0].size) {
                if (calcToText(grid[0][i]).toAsciiLower() == name.toAsciiLower()) {
                    fieldIndex = i
                    break
                }
            }
        case _ => ()
    }
    if (fieldIndex < 0 || fieldIndex >= grid[0].size) {
        return (grid, -1, ArrayList<Array<CalcValue>>(), Some(CalcError.Value))
    }
    let matched = ArrayList<Array<CalcValue>>()
    var row = 1
    while (row < grid.size) {
        var anyRow = false
        var conditionRow = 1
        while (conditionRow < criteria.size) {
            var all = true
            for (col in 0..criteria[0].size) {
                let condition = criteria[conditionRow][col]
                match (condition) {
                    case Empty => ()
                    case _ =>
                        if (col >= grid[0].size) {
                            all = false
                            break
                        }
                        var dataValue = CalcValue.Empty
                        if (row < grid.size && col < grid[row].size) {
                            dataValue = grid[row][col]
                        }
                        if (!criteriaMatch(dataValue, condition)) {
                            all = false
                            break
                        }
                }
            }
            if (all) {
                anyRow = true
                break
            }
            conditionRow++
        }
        if (anyRow) {
            matched.add(grid[row])
        }
        row++
    }
    (grid, fieldIndex, matched, None<CalcError>)
}

internal func fnDatabase(ev: Evaluator, args: Array<Expr>, mode: String): CalcValue {
    let (grid, fieldIndex, matched, error) = dbRows(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let values = ArrayList<CalcValue>()
    for (row in matched) {
        if (fieldIndex < row.size) {
            values.add(row[fieldIndex])
        }
    }
    match (mode) {
        case "count" =>
            var count: Int64 = 0
            for (v in values) {
                match (v) {
                    case Number(_) => count++
                    case _ => ()
                }
            }
            CalcValue.Number(Float64(count))
        case "counta" => CalcValue.Number(Float64(values.size))
        case "sum" => aggregateNumbers(values, "sum")
        case "average" => aggregateNumbers(values, "average")
        case "max" => aggregateNumbers(values, "max")
        case "min" => aggregateNumbers(values, "min")
        case "product" => aggregateNumbers(values, "product")
        case "stdev" => aggregateNumbers(values, "stdev")
        case "stdevp" => aggregateNumbers(values, "stdevp")
        case "var" => aggregateNumbers(values, "var")
        case "varp" => aggregateNumbers(values, "varp")
        case _ =>
            if (values.size == 0) {
                CalcValue.Error(CalcError.Value)
            } else if (values.size > 1) {
                CalcValue.Error(CalcError.Num)
            } else {
                values[0]
            }
    }
}

private func aggregateNumbers(values: ArrayList<CalcValue>, mode: String): CalcValue {
    let nums = ArrayList<Float64>()
    for (v in values) {
        match (v) {
            case Number(n) => nums.add(n)
            case Error(e) => return CalcValue.Error(e)
            case _ => ()
        }
    }
    if (nums.size == 0) {
        return if (mode == "sum" || mode == "product") { CalcValue.Number(0.0) } else { CalcValue.Error(CalcError.DivZero) }
    }
    var total = if (mode == "product") { 1.0 } else { 0.0 }
    for (v in nums) {
        if (mode == "product") {
            total *= v
        } else {
            total += v
        }
    }
    match (mode) {
        case "sum" => CalcValue.Number(total)
        case "product" => CalcValue.Number(total)
        case "average" => CalcValue.Number(total / Float64(nums.size))
        case "max" =>
            var best = nums[0]
            for (v in nums) {
                if (v > best) { best = v }
            }
            CalcValue.Number(best)
        case "min" =>
            var best = nums[0]
            for (v in nums) {
                if (v < best) { best = v }
            }
            CalcValue.Number(best)
        case "stdev" | "stdevp" =>
            let sample = mode == "stdev"
            let result = stdevOf(nums, sample)
            match (result) {
                case Some(v) => CalcValue.Number(v)
                case None => CalcValue.Error(CalcError.DivZero)
            }
        case _ =>
            let sample = mode == "var"
            let result = stdevOf(nums, sample)
            match (result) {
                case Some(v) => CalcValue.Number(v * v)
                case None => CalcValue.Error(CalcError.DivZero)
            }
    }
}

// ---------------------------------------------------------------- 小计/聚合

internal func fnSubtotal(ev: Evaluator, args: Array<Expr>): CalcValue {
    let code = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0) % 100
    let rest = args[1..args.size]
    match (code) {
        case 1 => fnAverage(ev, rest)
        case 2 => fnCount(ev, rest)
        case 3 => fnCountA(ev, rest)
        case 4 => fnMinMax(ev, rest, false)
        case 5 => fnMinMax(ev, rest, true)
        case 6 => fnProduct(ev, rest)
        case 7 => fnStdev(ev, rest, true)
        case 8 => fnStdev(ev, rest, false)
        case 9 => fnSum(ev, rest)
        case 10 => fnVariance(ev, rest, true)
        case 11 => fnVariance(ev, rest, false)
        case _ => CalcValue.Error(CalcError.Value)
    }
}

internal func fnAggregate(ev: Evaluator, args: Array<Expr>): CalcValue {
    let code = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let rest = args[2..args.size]
    match (code) {
        case 1 => fnAverage(ev, rest)
        case 2 => fnCount(ev, rest)
        case 3 => fnCountA(ev, rest)
        case 4 => fnMinMax(ev, rest, false)
        case 5 => fnMinMax(ev, rest, true)
        case 6 => fnProduct(ev, rest)
        case 7 => fnStdev(ev, rest, true)
        case 8 => fnStdev(ev, rest, false)
        case 9 => fnSum(ev, rest)
        case 10 => fnVariance(ev, rest, true)
        case 11 => fnVariance(ev, rest, false)
        case 12 => fnMedian(ev, rest)
        case 13 => fnMode(ev, rest)
        case 14 => fnLargeSmall(ev, rest, true)
        case 15 => fnLargeSmall(ev, rest, false)
        case 16 => fnPercentile(ev, rest)
        case 17 => fnQuartile(ev, rest)
        case _ => CalcValue.Error(CalcError.Value)
    }
}

// ---------------------------------------------------------------- 矩阵/单位

internal func fnMunit(ev: Evaluator, args: Array<Expr>): CalcValue {
    let n = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    if (n < 1 || n > 100) {
        return CalcValue.Error(CalcError.Num)
    }
    let rows = ArrayList<Array<CalcValue>>()
    for (r in 0..n) {
        let line = ArrayList<CalcValue>()
        for (c in 0..n) {
            line.add(CalcValue.Number(if (r == c) { 1.0 } else { 0.0 }))
        }
        rows.add(line.toArray())
    }
    CalcValue.ArrayValue(rows.toArray())
}

internal func fnMdeterm(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let n = Int64(grid.size)
    if (n < 1 || n > 8) {
        return CalcValue.Error(CalcError.Value)
    }
    let matrix = ArrayList<ArrayList<Float64>>()
    for (row in grid) {
        let line = ArrayList<Float64>()
        for (item in row) {
            match (item) {
                case Number(v) => line.add(v)
                case _ => return CalcValue.Error(CalcError.Value)
            }
        }
        if (Int64(line.size) != n) {
            return CalcValue.Error(CalcError.Value)
        }
        matrix.add(line)
    }
    CalcValue.Number(determinant(matrix))
}

private func determinant(m: ArrayList<ArrayList<Float64>>): Float64 {
    let n = Int64(m.size)
    if (n == 1) {
        return m[0][0]
    }
    if (n == 2) {
        return m[0][0] * m[1][1] - m[0][1] * m[1][0]
    }
    var total = 0.0
    for (col in 0..n) {
        let minor = ArrayList<ArrayList<Float64>>()
        for (row in 1..n) {
            let line = ArrayList<Float64>()
            for (c in 0..n) {
                if (c != col) {
                    line.add(m[row][c])
                }
            }
            minor.add(line)
        }
        let sign = if (col % 2 == 0) { 1.0 } else { -1.0 }
        total += sign * m[0][col] * determinant(minor)
    }
    total
}

internal func fnMinverse(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let n = Int64(grid.size)
    if (n < 1 || n > 3) {
        return CalcValue.Error(CalcError.Value)
    }
    let m = ArrayList<ArrayList<Float64>>()
    for (row in grid) {
        let line = ArrayList<Float64>()
        for (item in row) {
            match (item) {
                case Number(v) => line.add(v)
                case _ => return CalcValue.Error(CalcError.Value)
            }
        }
        if (Int64(line.size) != n) {
            return CalcValue.Error(CalcError.Value)
        }
        m.add(line)
    }
    let det = determinant(m)
    if (det == 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let rows = ArrayList<Array<CalcValue>>()
    for (r in 0..n) {
        let line = ArrayList<CalcValue>()
        for (c in 0..n) {
            let cofactor = ArrayList<ArrayList<Float64>>()
            for (rr in 0..n) {
                if (rr == r) { continue }
                let minorLine = ArrayList<Float64>()
                for (cc in 0..n) {
                    if (cc == c) { continue }
                    minorLine.add(m[rr][cc])
                }
                cofactor.add(minorLine)
            }
            let minorDet = if (cofactor.size == 0) { 1.0 } else { determinant(cofactor) }
            let sign = if ((r + c) % 2 == 0) { 1.0 } else { -1.0 }
            // 伴随矩阵转置：元素 (r,c) = cofactor(c,r)/det
            line.add(CalcValue.Number(sign * minorDet / det))
        }
        rows.add(line.toArray())
    }
    // 上面的循环按 (c,r) 取余子式才等价于转置，这里做一次显式转置修正
    let transposed = ArrayList<Array<CalcValue>>()
    for (r in 0..n) {
        let line = ArrayList<CalcValue>()
        for (c in 0..n) {
            line.add(rows[c][r])
        }
        transposed.add(line.toArray())
    }
    CalcValue.ArrayValue(transposed.toArray())
}

internal func fnConvert(ev: Evaluator, args: Array<Expr>): CalcValue {
    let value = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let from = calcToText(scalarize(ev.arg(args, 1))).toAsciiLower()
    let to = calcToText(scalarize(ev.arg(args, 2))).toAsciiLower()
    if (from == "c" && to == "f") {
        return CalcValue.Number(value * 9.0 / 5.0 + 32.0)
    }
    if (from == "f" && to == "c") {
        return CalcValue.Number((value - 32.0) * 5.0 / 9.0)
    }
    if (from == "c" && to == "k") {
        return CalcValue.Number(value + 273.15)
    }
    if (from == "k" && to == "c") {
        return CalcValue.Number(value - 273.15)
    }
    if (from == "f" && to == "k") {
        return CalcValue.Number((value - 32.0) * 5.0 / 9.0 + 273.15)
    }
    if (from == "k" && to == "f") {
        return CalcValue.Number((value - 273.15) * 9.0 / 5.0 + 32.0)
    }
    let factors = convertFactors()
    let fromFactor = match (factors.get(from)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.NotAvailable)
    }
    let toFactor = match (factors.get(to)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.NotAvailable)
    }
    CalcValue.Number(value * fromFactor / toFactor)
}

private func convertFactors(): HashMap<String, Float64> {
    let map = HashMap<String, Float64>()
    map.add("m", 1.0)
    map.add("km", 1000.0)
    map.add("cm", 0.01)
    map.add("mm", 0.001)
    map.add("in", 0.0254)
    map.add("ft", 0.3048)
    map.add("yd", 0.9144)
    map.add("mi", 1609.344)
    map.add("kg", 1.0)
    map.add("g", 0.001)
    map.add("mg", 0.000001)
    map.add("lbm", 0.45359237)
    map.add("ozm", 0.028349523125)
    map.add("l", 1.0)
    map.add("ml", 0.001)
    map.add("day", 86400.0)
    map.add("hour", 3600.0)
    map.add("min", 60.0)
    map.add("sec", 1.0)
    map
}

// ---------------------------------------------------------------- 现金流的日期版

internal func fnXnpv(ev: Evaluator, args: Array<Expr>): CalcValue {
    let rate = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let (values, valueError) = numbersOf(ev, args, 1)
    match (valueError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let (dates, dateError) = numbersOf(ev, args, 2)
    match (dateError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size != dates.size || values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    let base = dates[0]
    var total = 0.0
    for (i in 0..values.size) {
        total += values[i] / pow(1.0 + rate, (dates[i] - base) / 365.0)
    }
    CalcValue.Number(total)
}

internal func fnXirr(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, valueError) = numbersOf(ev, args, 0)
    match (valueError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let (dates, dateError) = numbersOf(ev, args, 1)
    match (dateError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size != dates.size || values.size < 2) {
        return CalcValue.Error(CalcError.Num)
    }
    let base = dates[0]
    var low = -0.9999
    var high = 10.0
    var fLow = xnpvAt(values, dates, base, low)
    var fHigh = xnpvAt(values, dates, base, high)
    if (fLow * fHigh > 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mid = 0.0
    for (_ in 0..200) {
        mid = (low + high) / 2.0
        let fMid = xnpvAt(values, dates, base, mid)
        if (abs(fMid) < 1e-8) {
            return CalcValue.Number(mid)
        }
        if (fLow * fMid < 0.0) {
            high = mid
        } else {
            low = mid
            fLow = fMid
        }
    }
    CalcValue.Number(mid)
}

private func xnpvAt(values: ArrayList<Float64>, dates: ArrayList<Float64>, base: Float64, rate: Float64): Float64 {
    var total = 0.0
    for (i in 0..values.size) {
        total += values[i] / pow(1.0 + rate, (dates[i] - base) / 365.0)
    }
    total
}

internal func fnTbillPrice(ev: Evaluator, args: Array<Expr>): CalcValue {
    let settlement = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let maturity = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let discount = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let days = maturity - settlement
    if (days <= 0.0 || discount <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(100.0 * (1.0 - discount * days / 360.0))
}

// ---------------------------------------------------------------- 信息/文本零碎

internal func fnFormulaText(ev: Evaluator, args: Array<Expr>, textMode: Bool): CalcValue {
    let cell = match (args[0]) {
        case Ref(sheet, value) => (sheet, value)
        case _ => return CalcValue.Error(CalcError.NotAvailable)
    }
    let name = match (cell[0]) {
        case Some(v) => v
        case None => ""
    }
    let source = ev.resolver.formulaAt(name, cell[1].row, cell[1].col)
    match (source) {
        case Some(formula) => if (textMode) { CalcValue.Text("=${formula}") } else { CalcValue.Boolean(true) }
        case None => if (textMode) { CalcValue.Error(CalcError.NotAvailable) } else { CalcValue.Boolean(false) }
    }
}

internal func fnCell(ev: Evaluator, args: Array<Expr>): CalcValue {
    let infoType = calcToText(scalarize(ev.arg(args, 0))).toAsciiLower()
    let (sheet, cellRef) = match (args[1]) {
        case Ref(s, value) => (match (s) {
            case Some(v) => v
            case None => ""
        }, value)
        case _ => ("", CellRef(1, 1))
    }
    match (infoType) {
        case "address" => CalcValue.Text(CellRef(cellRef.row, cellRef.col, rowAbs: true, colAbs: true).toA1())
        case "row" => CalcValue.Number(Float64(cellRef.row))
        case "col" => CalcValue.Number(Float64(cellRef.col))
        case "width" => CalcValue.Number(8.43)
        case "type" =>
            let value = ev.resolver.valueAt(sheet, cellRef.row, cellRef.col)
            match (value) {
                case Text(_) => CalcValue.Text("t")
                case Boolean(_) => CalcValue.Text("b")
                case Error(_) => CalcValue.Text("e")
                case Empty => CalcValue.Text("b")
                case _ => CalcValue.Text("n")
            }
        case _ => CalcValue.Error(CalcError.Value)
    }
}

internal func fnInfo(ev: Evaluator, args: Array<Expr>): CalcValue {
    let kind = calcToText(scalarize(ev.arg(args, 0))).toAsciiLower()
    match (kind) {
        case "system" => CalcValue.Text("Linux")
        case "release" => CalcValue.Text("1.0")
        case "osversion" => CalcValue.Text("Linux")
        case "recalc" => CalcValue.Text("Automatic")
        case "numfile" => CalcValue.Number(1.0)
        case "directory" => CalcValue.Text("/")
        case _ => CalcValue.Error(CalcError.Value)
    }
}

internal func fnCountUnique(ev: Evaluator, args: Array<Expr>): CalcValue {
    let seen = ArrayList<String>()
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            let key = item.toString()
            if (!seen.contains(key)) {
                seen.add(key)
            }
        }
    }
    CalcValue.Number(Float64(seen.size))
}

internal func fnProb(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, valueError) = numbersOf(ev, args, 0)
    match (valueError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let (probs, probError) = numbersOf(ev, args, 1)
    match (probError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let lower = numberArg(ev, args, 2, 0.0) ?? 0.0
    let upper = numberArg(ev, args, 3, lower) ?? lower
    if (values.size != probs.size) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    var total = 0.0
    for (i in 0..values.size) {
        if (values[i] >= lower && values[i] <= upper) {
            total += probs[i]
        }
    }
    CalcValue.Number(total)
}

internal func fnPhonetic(ev: Evaluator, args: Array<Expr>): CalcValue {
    CalcValue.Text(calcToText(scalarize(ev.arg(args, 0))))
}
