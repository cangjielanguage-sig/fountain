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

// ---------------------------------------------------------------- 统计扩展

private func sortedNumbers(ev: Evaluator, args: Array<Expr>): (ArrayList<Float64>, ?CalcError) {
    let values = ArrayList<Float64>()
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return (values, Some(e))
            case None => ()
        }
        for (v in nums) {
            values.add(v)
        }
    }
    for (i in 1..values.size) {
        let key = values[i]
        var j = i - 1
        while (j >= 0 && values[j] > key) {
            values[j + 1] = values[j]
            j--
        }
        values[j + 1] = key
    }
    (values, None<CalcError>)
}

private func stdevOf(values: ArrayList<Float64>, sample: Bool): ?Float64 {
    let n = values.size
    if (sample && n < 2) {
        return None<Float64>
    }
    if (n < 1) {
        return None<Float64>
    }
    var mean = 0.0
    for (v in values) {
        mean += v
    }
    mean /= Float64(n)
    var total = 0.0
    for (v in values) {
        let d = v - mean
        total += d * d
    }
    let divisor = if (sample) { Float64(n - 1) } else { Float64(n) }
    Some(sqrt(total / divisor))
}

internal func fnStdev(ev: Evaluator, args: Array<Expr>, sample: Bool): CalcValue {
    let values = ArrayList<Float64>()
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            values.add(v)
        }
    }
    match (stdevOf(values, sample)) {
        case Some(v) => CalcValue.Number(v)
        case None => CalcValue.Error(CalcError.DivZero)
    }
}

internal func fnVariance(ev: Evaluator, args: Array<Expr>, sample: Bool): CalcValue {
    let values = ArrayList<Float64>()
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            values.add(v)
        }
    }
    match (stdevOf(values, sample)) {
        case Some(v) => CalcValue.Number(v * v)
        case None => CalcValue.Error(CalcError.DivZero)
    }
}

internal func fnLargeSmall(ev: Evaluator, args: Array<Expr>, largest: Bool): CalcValue {
    let (values, error) = sortedNumbers(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let kValue = ev.arg(args, args.size - 1)
    // 最后一个实参是 k；前面的都参与取值
    let k = match (calcToNumber(scalarize(kValue))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    // sortedNumbers 把 k 也算了进去：这里改为只取前 n-1 个实参
    let real = ArrayList<Float64>()
    for (i in 0..(args.size - 1)) {
        let (nums, err) = numbersOf(ev, args, i)
        match (err) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            real.add(v)
        }
    }
    for (i in 1..real.size) {
        let key = real[i]
        var j = i - 1
        while (j >= 0 && real[j] > key) {
            real[j + 1] = real[j]
            j--
        }
        real[j + 1] = key
    }
    if (k < 1 || k > real.size) {
        return CalcValue.Error(CalcError.Num)
    }
    if (largest) {
        CalcValue.Number(real[real.size - k])
    } else {
        CalcValue.Number(real[k - 1])
    }
}

internal func fnRank(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let (values, error) = numbersOf(ev, args, 1)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var ascending = false
    if (args.size > 2) {
        ascending = match (calcToBool(scalarize(ev.arg(args, 2)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var rank: Int64 = 1
    var found = false
    for (v in values) {
        if (v == number) {
            found = true
        } else if ((ascending && v < number) || (!ascending && v > number)) {
            rank++
        }
    }
    if (!found) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    CalcValue.Number(Float64(rank))
}

internal func fnPercentile(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNumbers(ev, [args[0]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    let k = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (k < 0.0 || k > 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let position = k * Float64(values.size - 1)
    let lower = Int64(floor(position))
    let upper = Int64(ceil(position))
    let fraction = position - Float64(lower)
    let lowValue = values[lower]
    let highValue = values[upper]
    CalcValue.Number(lowValue + (highValue - lowValue) * fraction)
}

internal func fnQuartile(ev: Evaluator, args: Array<Expr>): CalcValue {
    let quart = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (quart < 0 || quart > 4) {
        return CalcValue.Error(CalcError.Num)
    }
    let k = Float64(quart) / 4.0
    fnPercentile(ev, [args[0], Expr.Lit(CalcValue.Number(k))])
}

internal func fnMode(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNumbers(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    var best = values[0]
    var bestCount: Int64 = 0
    var i: Int64 = 0
    while (i < values.size) {
        var j = i
        while (j < values.size && values[j] == values[i]) {
            j++
        }
        let count = j - i
        if (count > bestCount) {
            bestCount = count
            best = values[i]
        }
        i = j
    }
    if (bestCount < 2) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    CalcValue.Number(best)
}

private func pairedLists(ev: Evaluator, args: Array<Expr>): (ArrayList<Float64>, ArrayList<Float64>, ?CalcError) {
    let xs = ArrayList<Float64>()
    let ys = ArrayList<Float64>()
    let (xNums, xError) = numbersOf(ev, args, 0)
    match (xError) {
        case Some(e) => return (xs, ys, Some(e))
        case None => ()
    }
    let (yNums, yError) = numbersOf(ev, args, 1)
    match (yError) {
        case Some(e) => return (xs, ys, Some(e))
        case None => ()
    }
    if (xNums.size != yNums.size || xNums.size == 0) {
        return (xs, ys, Some(CalcError.NotAvailable))
    }
    for (i in 0..xNums.size) {
        xs.add(xNums[i])
        ys.add(yNums[i])
    }
    (xs, ys, None<CalcError>)
}

internal func fnCorrel(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (xs, ys, error) = pairedLists(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let n = xs.size
    if (n < 2) {
        return CalcValue.Error(CalcError.DivZero)
    }
    var mx = 0.0
    var my = 0.0
    for (i in 0..n) {
        mx += xs[i]
        my += ys[i]
    }
    mx /= Float64(n)
    my /= Float64(n)
    var cov = 0.0
    var vx = 0.0
    var vy = 0.0
    for (i in 0..n) {
        let dx = xs[i] - mx
        let dy = ys[i] - my
        cov += dx * dy
        vx += dx * dx
        vy += dy * dy
    }
    if (vx == 0.0 || vy == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(cov / sqrt(vx * vy))
}

internal func fnSlopeIntercept(ev: Evaluator, args: Array<Expr>, slope: Bool): CalcValue {
    // Excel 签名：SLOPE(known_y's, known_x's)
    let (ys, xs, error) = pairedLists(ev, [args[0], args[1]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let n = xs.size
    if (n < 2) {
        return CalcValue.Error(CalcError.DivZero)
    }
    var mx = 0.0
    var my = 0.0
    for (i in 0..n) {
        mx += xs[i]
        my += ys[i]
    }
    mx /= Float64(n)
    my /= Float64(n)
    var cov = 0.0
    var vx = 0.0
    for (i in 0..n) {
        let dx = xs[i] - mx
        cov += dx * (ys[i] - my)
        vx += dx * dx
    }
    if (vx == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    let m = cov / vx
    if (slope) {
        return CalcValue.Number(m)
    }
    CalcValue.Number(my - m * mx)
}

internal func fnForecast(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    // 参数顺序：x, known_y, known_x
    let (ys, xs, error) = pairedLists(ev, [args[1], args[2]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let n = xs.size
    if (n < 2) {
        return CalcValue.Error(CalcError.DivZero)
    }
    var mx = 0.0
    var my = 0.0
    for (i in 0..n) {
        mx += xs[i]
        my += ys[i]
    }
    mx /= Float64(n)
    my /= Float64(n)
    var cov = 0.0
    var vx = 0.0
    for (i in 0..n) {
        let dx = xs[i] - mx
        cov += dx * (ys[i] - my)
        vx += dx * dx
    }
    if (vx == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    let m = cov / vx
    CalcValue.Number(my + m * (x - mx))
}

// ---------------------------------------------------------------- 查找扩展

internal func fnHLookup(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let grid = gridOf(ev.arg(args, 1))
    if (grid.size == 0) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    let rowIndex = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (rowIndex < 1 || rowIndex > grid.size) {
        return CalcValue.Error(CalcError.Ref)
    }
    var approximate = true
    if (args.size > 3) {
        approximate = match (calcToBool(scalarize(ev.arg(args, 3)))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    var bestCol: Int64 = -1
    for (col in 0..grid[0].size) {
        let order = compareCalc(grid[0][col], lookup)
        match (order) {
            case Some(0) => if (rowIndex <= grid.size && col < grid[rowIndex - 1].size) {
                return grid[rowIndex - 1][col]
            } else {
                return CalcValue.Error(CalcError.Ref)
            }
            case Some(v) => if (approximate && v < 0) {
                bestCol = col
            }
            case None => ()
        }
    }
    if (approximate && bestCol >= 0 && rowIndex <= grid.size && bestCol < grid[rowIndex - 1].size) {
        return grid[rowIndex - 1][bestCol]
    }
    CalcValue.Error(CalcError.NotAvailable)
}

internal func fnLookup(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let grid = gridOf(ev.arg(args, 1))
    let resultGrid = if (args.size > 2) {
        gridOf(ev.arg(args, 2))
    } else {
        grid
    }
    let lookupValues = ArrayList<CalcValue>()
    if (grid.size == 1) {
        for (item in grid[0]) {
            lookupValues.add(item)
        }
    } else {
        for (row in grid) {
            if (row.size > 0) {
                lookupValues.add(row[0])
            }
        }
    }
    let results = ArrayList<CalcValue>()
    if (resultGrid.size == 1) {
        for (item in resultGrid[0]) {
            results.add(item)
        }
    } else {
        for (row in resultGrid) {
            if (row.size > 0) {
                results.add(row[0])
            }
        }
    }
    var best: Int64 = -1
    for (i in 0..lookupValues.size) {
        let order = match (compareCalc(lookupValues[i], lookup)) {
            case Some(v) => v
            case None => -1
        }
        if (order == 0 && i < results.size) {
            return results[i]
        }
        if (order < 0) {
            best = i
        }
    }
    if (best >= 0 && best < results.size) {
        return results[best]
    }
    CalcValue.Error(CalcError.NotAvailable)
}

internal func fnXLookup(ev: Evaluator, args: Array<Expr>): CalcValue {
    let lookup = scalarize(ev.arg(args, 0))
    let lookupValues = ArrayList<CalcValue>()
    for (row in gridOf(ev.arg(args, 1))) {
        for (item in row) {
            lookupValues.add(item)
        }
    }
    let results = ArrayList<CalcValue>()
    for (row in gridOf(ev.arg(args, 2))) {
        for (item in row) {
            results.add(item)
        }
    }
    var notFound: ?CalcValue = None
    if (args.size > 3) {
        notFound = Some(ev.arg(args, 3))
    }
    for (i in 0..lookupValues.size) {
        if (i >= results.size) {
            break
        }
        if (compareCalc(lookupValues[i], lookup) == Some(0)) {
            return results[i]
        }
    }
    match (notFound) {
        case Some(value) => value
        case None => CalcValue.Error(CalcError.NotAvailable)
    }
}

internal func fnChoose(ev: Evaluator, args: Array<Expr>): CalcValue {
    let index = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (index < 1 || index >= args.size) {
        return CalcValue.Error(CalcError.Value)
    }
    ev.arg(args, index)
}

private func refBoundsOf(expr: Expr): ?(?String, CellRef, CellRef) {
    match (expr) {
        case Ref(sheet, cell) => Some((sheet, cell, cell))
        case RangeExpr(sheet, from, to) => Some((sheet, from, to))
        case _ => None<(?String, CellRef, CellRef)>
    }
}

internal func fnOffset(ev: Evaluator, args: Array<Expr>): CalcValue {
    let bounds = refBoundsOf(args[0])
    if (bounds.isNone()) {
        return CalcValue.Error(CalcError.Ref)
    }
    let (sheet, from, to) = bounds.getOrThrow()
    let rows = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let cols = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    var height = to.row - from.row + 1
    var width = to.col - from.col + 1
    if (args.size > 3) {
        height = match (calcToNumber(scalarize(ev.arg(args, 3)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (args.size > 4) {
        width = match (calcToNumber(scalarize(ev.arg(args, 4)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (height < 1 || width < 1) {
        return CalcValue.Error(CalcError.Ref)
    }
    let startRow = from.row + rows
    let startCol = from.col + cols
    let endRow = startRow + height - 1
    let endCol = startCol + width - 1
    if (startRow < 1 || startCol < 1 || endRow > EXCEL_MAX_ROW || endCol > EXCEL_MAX_COL) {
        return CalcValue.Error(CalcError.Ref)
    }
    ev.rangeValue(sheet, CellRef(startRow, startCol), CellRef(endRow, endCol))
}

internal func fnIndirect(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0))).trimAscii()
    var body = text
    var sheet: ?String = None
    let bang = body.lastIndexOf("!")
    if (bang.isSome()) {
        let index = bang.getOrThrow()
        var name = body[0..index]
        if (name.startsWith("'") && name.endsWith("'") && name.size >= 2) {
            name = name[1..name.size - 1].replace("''", "'")
        }
        sheet = Some(name)
        body = body[index + 1..]
    }
    match (CellRef.parseRange(body)) {
        case Some(range) =>
            ev.rangeValue(sheet, range[0], range[1])
        case None => CalcValue.Error(CalcError.Ref)
    }
}

internal func fnRowColumn(ev: Evaluator, args: Array<Expr>, rowMode: Bool): CalcValue {
    if (args.size == 0) {
        return CalcValue.Error(CalcError.Value)
    }
    let bounds = refBoundsOf(args[0])
    if (bounds.isNone()) {
        return CalcValue.Error(CalcError.Value)
    }
    let (_, from, _) = bounds.getOrThrow()
    CalcValue.Number(Float64(if (rowMode) { from.row } else { from.col }))
}

internal func fnRowsColumns(ev: Evaluator, args: Array<Expr>, rowMode: Bool): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    if (rowMode) {
        return CalcValue.Number(Float64(grid.size))
    }
    let cols = if (grid.size == 0) { 0 } else { grid[0].size }
    CalcValue.Number(Float64(cols))
}

internal func fnTranspose(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    if (grid.size == 0) {
        return CalcValue.ArrayValue(Array<Array<CalcValue>>())
    }
    let cols = grid[0].size
    let rows = ArrayList<Array<CalcValue>>()
    for (col in 0..cols) {
        let line = ArrayList<CalcValue>()
        for (row in 0..grid.size) {
            line.add(if (col < grid[row].size) { grid[row][col] } else { CalcValue.Empty })
        }
        rows.add(line.toArray())
    }
    CalcValue.ArrayValue(rows.toArray())
}

// ---------------------------------------------------------------- 文本扩展

internal func fnSubstitute(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let old = calcToText(scalarize(ev.arg(args, 1)))
    let replacement = calcToText(scalarize(ev.arg(args, 2)))
    if (old.isEmpty()) {
        return CalcValue.Text(text)
    }
    var instance: Int64 = 0
    if (args.size > 3) {
        instance = match (calcToNumber(scalarize(ev.arg(args, 3)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (instance <= 0) {
        return CalcValue.Text(text.replace(old, replacement))
    }
    var seen: Int64 = 0
    var i: Int64 = 0
    var out = ""
    while (i < text.size) {
        if (i + old.size <= text.size && text[i..i + old.size] == old) {
            seen++
            if (seen == instance) {
                out += replacement
            } else {
                out += old
            }
            i += old.size
        } else {
            out += text[i..i + 1]
            i++
        }
    }
    CalcValue.Text(out)
}

internal func fnReplace(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let start = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let length = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    let replacement = calcToText(scalarize(ev.arg(args, 3)))
    let runes = runesOf(text)
    if (start < 1 || length < 0 || start > runes.size + 1) {
        return CalcValue.Error(CalcError.Value)
    }
    let prefix = runesJoin(runes, 0, start - 1)
    let suffix = runesJoin(runes, start - 1 + length, runes.size)
    CalcValue.Text(prefix + replacement + suffix)
}

internal func fnFindSearch(ev: Evaluator, args: Array<Expr>, caseSensitive: Bool): CalcValue {
    var needle = calcToText(scalarize(ev.arg(args, 0)))
    var haystack = calcToText(scalarize(ev.arg(args, 1)))
    var start: Int64 = 1
    if (args.size > 2) {
        start = match (calcToNumber(scalarize(ev.arg(args, 2)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (!caseSensitive) {
        needle = needle.toAsciiLower()
        haystack = haystack.toAsciiLower()
    }
    let runes = runesOf(haystack)
    let needleRunes = runesOf(needle)
    if (start < 1 || start > runes.size + 1) {
        return CalcValue.Error(CalcError.Value)
    }
    var i = start - 1
    while (i + needleRunes.size <= runes.size) {
        var matched = true
        for (j in 0..needleRunes.size) {
            if (runes[i + j] != needleRunes[j]) {
                matched = false
                break
            }
        }
        if (matched) {
            return CalcValue.Number(Float64(i + 1))
        }
        i++
    }
    CalcValue.Error(CalcError.Value)
}

internal func fnRept(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let times = match (calcToNumber(scalarize(ev.arg(args, 1)))) {
        case Some(v) => Int64(v)
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (times < 0) {
        return CalcValue.Error(CalcError.Value)
    }
    if (times == 0 || text.isEmpty()) {
        return CalcValue.Text("")
    }
    if (Int64(text.size) * times > 32767) {
        return CalcValue.Error(CalcError.Value)
    }
    let out = StringGenerator()
    for (_ in 0..times) {
        out.append<String>(text)
    }
    CalcValue.Text(out.toString())
}

internal func fnTextJoin(ev: Evaluator, args: Array<Expr>): CalcValue {
    let delimiter = calcToText(scalarize(ev.arg(args, 0)))
    let ignoreEmpty = match (calcToBool(scalarize(ev.arg(args, 1)))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let parts = ArrayList<String>()
    for (i in 2..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            let text = calcToText(item)
            if (ignoreEmpty && text.isEmpty()) {
                continue
            }
            parts.add(text)
        }
    }
    CalcValue.Text(joinText(parts, delimiter))
}

internal func fnExact(ev: Evaluator, args: Array<Expr>): CalcValue {
    let left = calcToText(scalarize(ev.arg(args, 0)))
    let right = calcToText(scalarize(ev.arg(args, 1)))
    CalcValue.Boolean(left == right)
}

internal func fnProper(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let out = StringGenerator()
    var startOfWord = true
    for (r in text.runes()) {
        let isLetter = (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z')
        if (!isLetter) {
            out.append(r)
            startOfWord = true
        } else if (startOfWord) {
            out.append<String>(r.toString().toAsciiUpper())
            startOfWord = false
        } else {
            out.append<String>(r.toString().toAsciiLower())
        }
    }
    CalcValue.Text(out.toString())
}

internal func fnClean(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let out = StringGenerator()
    for (r in text.runes()) {
        if (r.position() >= 32) {
            out.append(r)
        }
    }
    CalcValue.Text(out.toString())
}

internal func fnCharCode(ev: Evaluator, args: Array<Expr>, toChar: Bool): CalcValue {
    if (toChar) {
        let code = match (calcToNumber(scalarize(ev.arg(args, 0)))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
        if (code < 0 || code > 0x10FFFF) {
            return CalcValue.Error(CalcError.Value)
        }
        return CalcValue.Text(Rune(code).toString())
    }
    let text = calcToText(scalarize(ev.arg(args, 0)))
    if (text.isEmpty()) {
        return CalcValue.Error(CalcError.Value)
    }
    for (r in text.runes()) {
        return CalcValue.Number(Float64(r.position()))
    }
    CalcValue.Error(CalcError.Value)
}

internal func fnT(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (scalarize(ev.arg(args, 0))) {
        case Text(v) => CalcValue.Text(v)
        case _ => CalcValue.Text("")
    }
}
