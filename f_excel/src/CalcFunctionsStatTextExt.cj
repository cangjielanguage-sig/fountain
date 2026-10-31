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

private func sortedNums(ev: Evaluator, args: Array<Expr>): (ArrayList<Float64>, ?CalcError) {
    sortedNumbers(ev, args)
}

internal func fnAveDev(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mean = 0.0
    for (v in values) {
        mean += v
    }
    mean /= Float64(values.size)
    var total = 0.0
    for (v in values) {
        total += abs(v - mean)
    }
    CalcValue.Number(total / Float64(values.size))
}

internal func fnDevSq(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mean = 0.0
    for (v in values) {
        mean += v
    }
    mean /= Float64(values.size)
    var total = 0.0
    for (v in values) {
        total += (v - mean) * (v - mean)
    }
    CalcValue.Number(total)
}

internal func fnGeoMean(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var total = 0.0
    for (v in values) {
        if (v <= 0.0) {
            return CalcValue.Error(CalcError.Num)
        }
        total += log(v)
    }
    CalcValue.Number(exp(total / Float64(values.size)))
}

internal func fnHarMean(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var total = 0.0
    for (v in values) {
        if (v <= 0.0) {
            return CalcValue.Error(CalcError.Num)
        }
        total += 1.0 / v
    }
    CalcValue.Number(Float64(values.size) / total)
}

internal func fnSkewKurt(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let n = values.size
    if (n < 3) {
        return CalcValue.Error(CalcError.DivZero)
    }
    var mean = 0.0
    for (v in values) {
        mean += v
    }
    mean /= Float64(n)
    var m2 = 0.0
    var m3 = 0.0
    var m4 = 0.0
    for (v in values) {
        let d = v - mean
        m2 += d * d
        m3 += d * d * d
        m4 += d * d * d * d
    }
    let variance = m2 / Float64(n - 1)
    let sd = sqrt(variance)
    if (sd == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    match (kind) {
        case "skew" => CalcValue.Number(Float64(n) / Float64((n - 1) * (n - 2)) * (m3 / (sd * sd * sd)))
        case "skewp" =>
            let sigma = sqrt(m2 / Float64(n))
            CalcValue.Number((m3 / Float64(n)) / (sigma * sigma * sigma))
        case _ =>
            let term = Float64(n * (n + 1)) / Float64((n - 1) * (n - 2) * (n - 3)) *
                (m4 / (variance * variance))
            let correction = Float64(3 * (n - 1) * (n - 1)) / Float64((n - 2) * (n - 3))
            CalcValue.Number(term - correction)
    }
}

internal func fnTrimMean(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNumbers(ev, [args[0]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let percent = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (percent < 0.0 || percent >= 1.0 || values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var trim = Int64(floor(Float64(values.size) * percent / 2.0))
    if (trim * 2 >= values.size) {
        trim = (values.size - 1) / 2
    }
    var total = 0.0
    for (i in trim..(values.size - trim)) {
        total += values[i]
    }
    CalcValue.Number(total / Float64(values.size - trim * 2))
}

internal func fnPercentRank(ev: Evaluator, args: Array<Expr>, exclusive: Bool): CalcValue {
    let (values, error) = sortedNumbers(ev, [args[0]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let n = values.size
    if (n < 2) {
        return CalcValue.Error(CalcError.Num)
    }
    var below: Int64 = 0
    for (v in values) {
        if (v < x) {
            below++
        }
    }
    let denominator = if (exclusive) { Float64(n + 1) } else { Float64(n - 1) }
    let numerator = if (exclusive) { Float64(below + 1) } else { Float64(below) }
    CalcValue.Number(numerator / denominator)
}

internal func fnQuartileExclusive(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNumbers(ev, [args[0]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let quart = Int64(numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value))
    if (quart < 1 || quart > 3 || values.size < 4) {
        return CalcValue.Error(CalcError.Num)
    }
    let position = Float64(quart) * Float64(values.size + 1) / 4.0
    if (position < 1.0 || position > Float64(values.size)) {
        return CalcValue.Error(CalcError.Num)
    }
    let lower = Int64(floor(position)) - 1
    let upper = if (lower + 1 < values.size) { lower + 1 } else { lower }
    let fraction = position - floor(position)
    CalcValue.Number(values[lower] + (values[upper] - values[lower]) * fraction)
}

internal func fnDevA(ev: Evaluator, args: Array<Expr>, sample: Bool): CalcValue {
    let values = ArrayList<Float64>()
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            match (item) {
                case Number(v) => values.add(v)
                case Boolean(v) => values.add(if (v) { 1.0 } else { 0.0 })
                case Text(_) => values.add(0.0)
                case Error(e) => return CalcValue.Error(e)
                case _ => ()
            }
        }
    }
    match (stdevOf(values, sample)) {
        case Some(v) => CalcValue.Number(v)
        case None => CalcValue.Error(CalcError.DivZero)
    }
}

internal func fnVarianceA(ev: Evaluator, args: Array<Expr>, sample: Bool): CalcValue {
    let sd = fnDevA(ev, args, sample)
    match (sd) {
        case Number(v) => CalcValue.Number(v * v)
        case _ => sd
    }
}

internal func fnCovariance(ev: Evaluator, args: Array<Expr>, sample: Bool): CalcValue {
    let (xs, ys, error) = pairedLists(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let n = xs.size
    if (sample && n < 2) {
        return CalcValue.Error(CalcError.DivZero)
    }
    if (n < 1) {
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
    var total = 0.0
    for (i in 0..n) {
        total += (xs[i] - mx) * (ys[i] - my)
    }
    CalcValue.Number(total / Float64(if (sample) { n - 1 } else { n }))
}

internal func fnFisher(ev: Evaluator, args: Array<Expr>, inverse: Bool): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (inverse) {
        let e = exp(2.0 * x)
        return CalcValue.Number((e - 1.0) / (e + 1.0))
    }
    if (x <= -1.0 || x >= 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(0.5 * log((1.0 + x) / (1.0 - x)))
}

internal func fnStandardize(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let sd = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (sd <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number((x - mean) / sd)
}

internal func fnR(ev: Evaluator, args: Array<Expr>, rsq: Bool): CalcValue {
    let correlation = fnCorrel(ev, args)
    match (correlation) {
        case Number(v) => CalcValue.Number(if (rsq) { v * v } else { v })
        case _ => correlation
    }
}

internal func fnAverageA(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total = 0.0
    var count: Int64 = 0
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            match (item) {
                case Number(v) =>
                    total += v
                    count++
                case Boolean(v) =>
                    total += if (v) { 1.0 } else { 0.0 }
                    count++
                case Text(_) => count++
                case Error(e) => return CalcValue.Error(e)
                case _ => ()
            }
        }
    }
    if (count == 0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(total / Float64(count))
}

internal func fnMinMaxA(ev: Evaluator, args: Array<Expr>, minimum: Bool): CalcValue {
    var best = 0.0
    var seen = false
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            let value = match (item) {
                case Number(v) => v
                case Boolean(v) => if (v) { 1.0 } else { 0.0 }
                case Text(_) => 0.0
                case Error(e) => return CalcValue.Error(e)
                case _ => 0.0
            }
            if (!seen) {
                best = value
                seen = true
            } else if (minimum && value < best) {
                best = value
            } else if (!minimum && value > best) {
                best = value
            }
        }
    }
    CalcValue.Number(best)
}

internal func fnModeMult(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNums(ev, args)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (values.size == 0) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    var bestCount: Int64 = 0
    var i: Int64 = 0
    let modes = ArrayList<Float64>()
    while (i < values.size) {
        var j = i
        while (j < values.size && values[j] == values[i]) {
            j++
        }
        let count = j - i
        if (count > bestCount) {
            bestCount = count
            modes.clear()
            modes.add(values[i])
        } else if (count == bestCount && count > 1) {
            modes.add(values[i])
        }
        i = j
    }
    if (bestCount < 2) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    let rows = ArrayList<Array<CalcValue>>()
    for (v in modes) {
        rows.add([CalcValue.Number(v)])
    }
    CalcValue.ArrayValue(rows.toArray())
}

internal func fnRankAvg(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let (values, error) = numbersOf(ev, args, 1)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var ascending = false
    if (args.size > 2) {
        ascending = match (calcToBool(scalarize(ev.arg(args, 2)))) {
            case Some(v) => v
            case None => false
        }
    }
    var above: Int64 = 0
    var equal: Int64 = 0
    var found = false
    for (v in values) {
        if (v == number) {
            equal++
            found = true
        } else if ((ascending && v < number) || (!ascending && v > number)) {
            above++
        }
    }
    if (!found) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    CalcValue.Number(Float64(above) + (Float64(equal) + 1.0) / 2.0)
}

// ---------------------------------------------------------------- 信息扩展

internal func fnIsEvenOdd(ev: Evaluator, args: Array<Expr>, even: Bool): CalcValue {
    let x = Int64(numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value))
    CalcValue.Boolean(if (even) { x % 2 == 0 } else { x % 2 != 0 })
}

internal func fnN(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (scalarize(ev.arg(args, 0))) {
        case Number(v) => CalcValue.Number(v)
        case Boolean(v) => CalcValue.Number(if (v) { 1.0 } else { 0.0 })
        case _ => CalcValue.Number(0.0)
    }
}

internal func fnSheetCount(ev: Evaluator, args: Array<Expr>, count: Bool): CalcValue {
    CalcValue.Number(1.0)
}

internal func fnIsRef(ev: Evaluator, args: Array<Expr>): CalcValue {
    match (args[0]) {
        case Ref(_, _) => CalcValue.Boolean(true)
        case RangeExpr(_, _, _) => CalcValue.Boolean(true)
        case _ => CalcValue.Boolean(false)
    }
}

// ---------------------------------------------------------------- 文本扩展

internal func fnTextBeforeAfter(ev: Evaluator, args: Array<Expr>, before: Bool): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let delimiter = calcToText(scalarize(ev.arg(args, 1)))
    if (delimiter.isEmpty()) {
        return CalcValue.Error(CalcError.Value)
    }
    let position = text.indexOf(delimiter)
    match (position) {
        case Some(index) =>
            if (before) {
                CalcValue.Text(text[0..index])
            } else {
                CalcValue.Text(text[index + delimiter.size..text.size])
            }
        case None => CalcValue.Error(CalcError.NotAvailable)
    }
}

internal func fnTextSplit(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    let delimiter = calcToText(scalarize(ev.arg(args, 1)))
    let parts = text.split(delimiter)
    let rows = ArrayList<Array<CalcValue>>()
    for (part in parts) {
        rows.add([CalcValue.Text(part)])
    }
    CalcValue.ArrayValue(rows.toArray())
}

internal func fnNumberValue(ev: Evaluator, args: Array<Expr>): CalcValue {
    var text = calcToText(scalarize(ev.arg(args, 0))).trimAscii()
    var decimalSeparator = "."
    var groupSeparator = ","
    if (args.size > 1) {
        decimalSeparator = calcToText(scalarize(ev.arg(args, 1)))
    }
    if (args.size > 2) {
        groupSeparator = calcToText(scalarize(ev.arg(args, 2)))
    }
    text = text.replace(groupSeparator, "")
    text = text.replace(decimalSeparator, ".")
    var percent = false
    if (text.endsWith("%")) {
        percent = true
        text = text[0..text.size - 1]
    }
    match (parseNumberText(text)) {
        case Some(v) => CalcValue.Number(if (percent) { v / 100.0 } else { v })
        case None => CalcValue.Error(CalcError.Value)
    }
}

internal func fnDollarFixed(ev: Evaluator, args: Array<Expr>, dollar: Bool): CalcValue {
    let number = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var decimals: Int64 = 2
    if (args.size > 1) {
        decimals = Int64(numberArg(ev, args, 1, 2.0) ?? 2.0)
    }
    if (decimals < 0) {
        decimals = 0
    }
    var commas = true
    if (!dollar && args.size > 2) {
        commas = match (calcToBool(scalarize(ev.arg(args, 2)))) {
            case Some(v) => !v
            case None => true
        }
    }
    let pattern = if (commas) { "#,##0." + zeros(decimals) } else { "0." + zeros(decimals) }
    var text = formatFixed(abs(number), decimals)
    if (commas) {
        text = addThousandSeparators(text)
    }
    if (number < 0.0) {
        text = "(" + text + ")"
    }
    if (dollar) {
        text = "$" + text
    }
    CalcValue.Text(text)
}

private func zeros(count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += "0"
    }
    if (count == 0) {
        out = "0"
    }
    out
}

internal func fnWideAsc(ev: Evaluator, args: Array<Expr>): CalcValue {
    CalcValue.Text(calcToText(scalarize(ev.arg(args, 0))))
}

internal func fnByteText(ev: Evaluator, args: Array<Expr>, mode: String): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0)))
    match (mode) {
        case "lenb" => CalcValue.Number(Float64(text.toArray().size))
        case "leftb" =>
            let count = Int64(numberArg(ev, args, 1, 1.0) ?? 1.0)
            let bytes = text.toArray()
            CalcValue.Text(String.fromUtf8(bytes[0..min(count, Int64(bytes.size))]))
        case "rightb" =>
            let count = Int64(numberArg(ev, args, 1, 1.0) ?? 1.0)
            let bytes = text.toArray()
            let start = if (count >= Int64(bytes.size)) { 0 } else { Int64(bytes.size) - count }
            CalcValue.Text(String.fromUtf8(bytes[start..bytes.size]))
        case _ =>
            let start = Int64(numberArg(ev, args, 1, 1.0) ?? 1.0)
            let count = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
            let bytes = text.toArray()
            let from = if (start < 1) { 0 } else { start - 1 }
            let to = min(from + count, Int64(bytes.size))
            if (from >= Int64(bytes.size)) {
                CalcValue.Text("")
            } else {
                CalcValue.Text(String.fromUtf8(bytes[from..to]))
            }
    }
}

internal func fnValueToText(ev: Evaluator, args: Array<Expr>, arrayMode: Bool): CalcValue {
    if (arrayMode) {
        let values = flattenValues(ev.arg(args, 0))
        let parts = ArrayList<String>()
        for (item in values) {
            parts.add(calcToText(item))
        }
        return CalcValue.Text(joinText(parts, ", "))
    }
    CalcValue.Text(calcToText(scalarize(ev.arg(args, 0))))
}

private func min(a: Int64, b: Int64): Int64 {
    if (a < b) { a } else { b }
}
