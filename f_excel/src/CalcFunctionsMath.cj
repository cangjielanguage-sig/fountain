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

// ---------------------------------------------------------------- 数学

internal func fnSum(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total = 0.0
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            total += v
        }
    }
    CalcValue.Number(total)
}

internal func fnProduct(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total = 1.0
    var seen = false
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            total *= v
            seen = true
        }
    }
    if (!seen) {
        return CalcValue.Number(0.0)
    }
    CalcValue.Number(total)
}

internal func fnUnaryMath(ev: Evaluator, args: Array<Expr>, mode: String): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    match (mode) {
        case "abs" => CalcValue.Number(abs(x))
        case "sign" => CalcValue.Number(if (x > 0.0) { 1.0 } else if (x < 0.0) { -1.0 } else { 0.0 })
        case "sqrt" => if (x < 0.0) { CalcValue.Error(CalcError.Num) } else { CalcValue.Number(sqrt(x)) }
        case _ => CalcValue.Number(floor(x))
    }
}

/** Excel 的四舍五入：**远离零**，不是银行家舍入。 */
internal func roundHalfAway(value: Float64, digits: Int64): Float64 {
    var factor = 1.0
    if (digits >= 0) {
        for (_ in 0..digits) {
            factor *= 10.0
        }
    } else {
        for (_ in 0..(-digits)) {
            factor /= 10.0
        }
    }
    let scaled = value * factor
    let rounded = if (scaled >= 0.0) {
        floor(scaled + 0.5)
    } else {
        ceil(scaled - 0.5)
    }
    rounded / factor
}

internal func fnRound(ev: Evaluator, args: Array<Expr>, mode: String): CalcValue {
    let value = ev.arg(args, 0)
    match (firstError([value])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    var digits: Int64 = 0
    if (args.size > 1) {
        let digitsValue = ev.arg(args, 1)
        match (firstError([digitsValue])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        digits = match (calcToNumber(scalarize(digitsValue))) {
            case Some(v) => Int64(v)
            case None => return CalcValue.Error(CalcError.Value)
        }
    }
    if (digits > 15) {
        digits = 15
    }
    if (digits < -15) {
        digits = -15
    }
    match (mode) {
        case "round" => CalcValue.Number(roundHalfAway(x, digits))
        case "up" =>
            var factor = 1.0
            if (digits >= 0) {
                for (_ in 0..digits) {
                    factor *= 10.0
                }
            } else {
                for (_ in 0..(-digits)) {
                    factor /= 10.0
                }
            }
            let scaled = x * factor
            let rounded = if (scaled >= 0.0) { ceil(scaled) } else { floor(scaled) }
            CalcValue.Number(rounded / factor)
        case _ =>
            var factor = 1.0
            if (digits >= 0) {
                for (_ in 0..digits) {
                    factor *= 10.0
                }
            } else {
                for (_ in 0..(-digits)) {
                    factor /= 10.0
                }
            }
            let scaled = x * factor
            let rounded = if (scaled >= 0.0) { floor(scaled) } else { ceil(scaled) }
            CalcValue.Number(rounded / factor)
    }
}

internal func fnMod(ev: Evaluator, args: Array<Expr>): CalcValue {
    let a = ev.arg(args, 0)
    let b = ev.arg(args, 1)
    match (firstError([a, b])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = match (calcToNumber(scalarize(a))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let y = match (calcToNumber(scalarize(b))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    if (y == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(x - y * floor(x / y))
}

internal func fnPower(ev: Evaluator, args: Array<Expr>): CalcValue {
    let a = ev.arg(args, 0)
    let b = ev.arg(args, 1)
    match (firstError([a, b])) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = match (calcToNumber(scalarize(a))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let y = match (calcToNumber(scalarize(b))) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Value)
    }
    let result = pow(x, y)
    if (result.isNaN() || result.isInf()) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(result)
}

// ---------------------------------------------------------------- 条件聚合

private func sumIfCore(ev: Evaluator, args: Array<Expr>, average: Bool): CalcValue {
    let testGrid = gridOf(ev.arg(args, 0))
    let criteria = ev.arg(args, 1)
    let sumGrid = if (args.size > 2) {
        gridOf(ev.arg(args, 2))
    } else {
        testGrid
    }
    var total = 0.0
    var count: Int64 = 0
    for (row in 0..testGrid.size) {
        for (col in 0..testGrid[row].size) {
            let cell = testGrid[row][col]
            match (cell) {
                case Error(e) => return CalcValue.Error(e)
                case _ => ()
            }
            if (!criteriaMatch(cell, criteria)) {
                continue
            }
            if (row >= sumGrid.size || col >= sumGrid[row].size) {
                continue
            }
            match (sumGrid[row][col]) {
                case Number(v) =>
                    total += v
                    count++
                case Error(e) => return CalcValue.Error(e)
                case _ => ()
            }
        }
    }
    if (average) {
        if (count == 0) {
            return CalcValue.Error(CalcError.DivZero)
        }
        return CalcValue.Number(total / Float64(count))
    }
    CalcValue.Number(total)
}

internal func fnSumIf(ev: Evaluator, args: Array<Expr>): CalcValue {
    sumIfCore(ev, args, false)
}

internal func fnAverageIf(ev: Evaluator, args: Array<Expr>): CalcValue {
    sumIfCore(ev, args, true)
}

internal func fnSumIfs(ev: Evaluator, args: Array<Expr>): CalcValue {
    let sumGrid = gridOf(ev.arg(args, 0))
    var total = 0.0
    for (row in 0..sumGrid.size) {
        for (col in 0..sumGrid[row].size) {
            var matched = true
            var pair = 1
            while (pair + 1 < args.size) {
                let testGrid = gridOf(ev.arg(args, pair))
                let criteria = ev.arg(args, pair + 1)
                if (row >= testGrid.size || col >= testGrid[row].size ||
                    !criteriaMatch(testGrid[row][col], criteria)) {
                    matched = false
                    break
                }
                pair += 2
            }
            if (matched) {
                match (sumGrid[row][col]) {
                    case Number(v) => total += v
                    case Error(e) => return CalcValue.Error(e)
                    case _ => ()
                }
            }
        }
    }
    CalcValue.Number(total)
}

internal func fnAverage(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total = 0.0
    var count: Int64 = 0
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            total += v
            count++
        }
    }
    if (count == 0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(total / Float64(count))
}

internal func fnCount(ev: Evaluator, args: Array<Expr>): CalcValue {
    var count: Int64 = 0
    for (i in 0..args.size) {
        let value = ev.arg(args, i)
        match (value) {
            case Error(e) => return CalcValue.Error(e)
            case ArrayValue(rows) =>
                for (row in rows) {
                    for (item in row) {
                        match (item) {
                            case Number(_) => count++
                            case Error(e) => return CalcValue.Error(e)
                            case _ => ()
                        }
                    }
                }
            case Empty => ()
            case _ => if (calcToNumber(value).isSome()) {
                count++
            }
        }
    }
    CalcValue.Number(Float64(count))
}

internal func fnCountA(ev: Evaluator, args: Array<Expr>): CalcValue {
    var count: Int64 = 0
    for (i in 0..args.size) {
        for (item in flattenValues(ev.arg(args, i))) {
            match (item) {
                case Empty => ()
                case _ => count++
            }
        }
    }
    CalcValue.Number(Float64(count))
}

internal func fnCountBlank(ev: Evaluator, args: Array<Expr>): CalcValue {
    var count: Int64 = 0
    let value = ev.arg(args, 0)
    match (value) {
        case ArrayValue(rows) =>
            for (row in rows) {
                for (item in row) {
                    match (item) {
                        case Empty => count++
                        case _ => ()
                    }
                }
            }
        case Empty => count = 1
        case _ => ()
    }
    CalcValue.Number(Float64(count))
}

internal func fnCountIf(ev: Evaluator, args: Array<Expr>): CalcValue {
    let grid = gridOf(ev.arg(args, 0))
    let criteria = ev.arg(args, 1)
    var count: Int64 = 0
    for (row in grid) {
        for (item in row) {
            if (criteriaMatch(item, criteria)) {
                count++
            }
        }
    }
    CalcValue.Number(Float64(count))
}

internal func fnCountIfs(ev: Evaluator, args: Array<Expr>): CalcValue {
    let first = gridOf(ev.arg(args, 0))
    var count: Int64 = 0
    for (row in 0..first.size) {
        for (col in 0..first[row].size) {
            var matched = true
            var pair = 0
            while (pair + 1 < args.size) {
                let grid = gridOf(ev.arg(args, pair))
                let criteria = ev.arg(args, pair + 1)
                if (row >= grid.size || col >= grid[row].size ||
                    !criteriaMatch(grid[row][col], criteria)) {
                    matched = false
                    break
                }
                pair += 2
            }
            if (matched) {
                count++
            }
        }
    }
    CalcValue.Number(Float64(count))
}

internal func fnMinMax(ev: Evaluator, args: Array<Expr>, minimum: Bool): CalcValue {
    var best = 0.0
    var seen = false
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            if (!seen) {
                best = v
                seen = true
            } else if (minimum && v < best) {
                best = v
            } else if (!minimum && v > best) {
                best = v
            }
        }
    }
    if (!seen) {
        return CalcValue.Number(0.0)
    }
    CalcValue.Number(best)
}

internal func fnMedian(ev: Evaluator, args: Array<Expr>): CalcValue {
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
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    // 插入排序：样本量小，避免依赖 std 的比较器接口
    for (i in 1..values.size) {
        let key = values[i]
        var j = i - 1
        while (j >= 0 && values[j] > key) {
            values[j + 1] = values[j]
            j--
        }
        values[j + 1] = key
    }
    let n = values.size
    if (n % 2 == 1) {
        return CalcValue.Number(values[n / 2])
    }
    CalcValue.Number((values[n / 2 - 1] + values[n / 2]) / 2.0)
}
