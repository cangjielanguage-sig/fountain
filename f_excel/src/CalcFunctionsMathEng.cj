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

// ---------------------------------------------------------------- 三角/双曲

internal func fnTrigExt(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let result = match (kind) {
        case "acos" => if (x < -1.0 || x > 1.0) {
            return CalcValue.Error(CalcError.Num)
        } else {
            acos(x)
        }
        case "acosh" => if (x < 1.0) {
            return CalcValue.Error(CalcError.Num)
        } else {
            acosh(x)
        }
        case "asin" => if (x < -1.0 || x > 1.0) {
            return CalcValue.Error(CalcError.Num)
        } else {
            asin(x)
        }
        case "asinh" => asinh(x)
        case "atan" => atan(x)
        case "atanh" => if (x <= -1.0 || x >= 1.0) {
            return CalcValue.Error(CalcError.Num)
        } else {
            atanh(x)
        }
        case "cosh" => cosh(x)
        case "sinh" => sinh(x)
        case "tanh" => tanh(x)
        case "sec" => 1.0 / cos(x)
        case "sech" => 1.0 / cosh(x)
        case "csc" => if (sin(x) == 0.0) {
            return CalcValue.Error(CalcError.DivZero)
        } else {
            1.0 / sin(x)
        }
        case "csch" => if (sinh(x) == 0.0) {
            return CalcValue.Error(CalcError.DivZero)
        } else {
            1.0 / sinh(x)
        }
        case "cot" => if (tan(x) == 0.0) {
            return CalcValue.Error(CalcError.DivZero)
        } else {
            1.0 / tan(x)
        }
        case _ => if (tanh(x) == 0.0) {
            return CalcValue.Error(CalcError.DivZero)
        } else {
            1.0 / tanh(x)
        }
    }
    CalcValue.Number(result)
}

internal func fnAtan2(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let y = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (x == 0.0 && y == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(atan2(y, x))
}

internal func fnEvenOdd(ev: Evaluator, args: Array<Expr>, even: Bool): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (x == 0.0) {
        return CalcValue.Number(0.0)
    }
    let magnitude = abs(x)
    var rounded = if (even) { ceil(magnitude / 2.0) * 2.0 } else { ceil((magnitude - 1.0) / 2.0) * 2.0 + 1.0 }
    if (rounded == 0.0) {
        rounded = if (even) { 2.0 } else { 1.0 }
    }
    CalcValue.Number(if (x < 0.0) { -rounded } else { rounded })
}

internal func fnQuotient(ev: Evaluator, args: Array<Expr>): CalcValue {
    let a = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let b = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (b == 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    let quotient = a / b
    CalcValue.Number(if (quotient >= 0.0) { floor(quotient) } else { ceil(quotient) })
}

private func factorial(n: Int64): Float64 {
    if (n < 0) {
        return 0.0
    }
    var result = 1.0
    var i: Int64 = 2
    while (i <= n) {
        result *= Float64(i)
        i++
    }
    result
}

internal func fnCombin(ev: Evaluator, args: Array<Expr>, repetition: Bool): CalcValue {
    let n = Int64(numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value))
    let k = Int64(numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value))
    if (n < 0 || k < 0) {
        return CalcValue.Error(CalcError.Num)
    }
    let top = if (repetition) { n + k - 1 } else { n }
    if (k > top) {
        return CalcValue.Error(CalcError.Num)
    }
    // 逐项相除，避免 n! 溢出
    var result = 1.0
    var i: Int64 = 1
    while (i <= k) {
        result = result * Float64(top - k + i) / Float64(i)
        i++
    }
    CalcValue.Number(floor(result + 0.5))
}

internal func fnPermut(ev: Evaluator, args: Array<Expr>, repetition: Bool): CalcValue {
    let n = Int64(numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value))
    let k = Int64(numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value))
    if (n < 0 || k < 0 || (!repetition && k > n)) {
        return CalcValue.Error(CalcError.Num)
    }
    if (repetition) {
        return CalcValue.Number(pow(Float64(n), Float64(k)))
    }
    var result = 1.0
    var i: Int64 = 0
    while (i < k) {
        result *= Float64(n - i)
        i++
    }
    CalcValue.Number(result)
}

internal func fnMultinomial(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total: Int64 = 0
    var denominator = 1.0
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            let n = Int64(v)
            if (n < 0) {
                return CalcValue.Error(CalcError.Num)
            }
            total += n
            denominator *= factorial(n)
        }
    }
    if (total == 0) {
        return CalcValue.Number(1.0)
    }
    CalcValue.Number(floor(factorial(total) / denominator + 0.5))
}

internal func fnFactDouble(ev: Evaluator, args: Array<Expr>): CalcValue {
    let n = Int64(numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value))
    if (n < -1) {
        return CalcValue.Error(CalcError.Num)
    }
    var result = 1.0
    var i = if (n % 2 == 0) { 2 } else { 1 }
    while (i <= n) {
        result *= Float64(i)
        i += 2
    }
    CalcValue.Number(result)
}

internal func fnSqrtPi(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (x < 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(sqrt(x * 3.141592653589793))
}

internal func fnSumSq(ev: Evaluator, args: Array<Expr>): CalcValue {
    var total = 0.0
    for (i in 0..args.size) {
        let (nums, error) = numbersOf(ev, args, i)
        match (error) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        for (v in nums) {
            total += v * v
        }
    }
    CalcValue.Number(total)
}

internal func fnSumX2(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let xPair = numbersOf(ev, args, 0)
    let xNums = xPair[0]
    match (xPair[1]) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let yPair = numbersOf(ev, args, 1)
    let yNums = yPair[0]
    match (yPair[1]) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    if (xNums.size != yNums.size) {
        return CalcValue.Error(CalcError.NotAvailable)
    }
    var total = 0.0
    for (i in 0..xNums.size) {
        let a = xNums[i]
        let b = yNums[i]
        match (kind) {
            case "my" => total += a * a - b * b
            case "py" => total += a * a + b * b
            case _ => total += (a - b) * (a - b)
        }
    }
    CalcValue.Number(total)
}

internal func fnSeriesSum(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let n = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let m = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (args.size < 4) {
        return CalcValue.Error(CalcError.Value)
    }
    let (coeffs, error) = numbersOf(ev, args, 3)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    var total = 0.0
    for (i in 0..coeffs.size) {
        total += coeffs[i] * pow(x, n + Float64(i) * m)
    }
    CalcValue.Number(total)
}

internal func fnCeilingMath(ev: Evaluator, args: Array<Expr>, up: Bool, precise: Bool): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var significance = 1.0
    if (args.size > 1) {
        significance = numberArg(ev, args, 1, 1.0) ?? return CalcValue.Error(CalcError.Value)
    }
    if (significance == 0.0) {
        return CalcValue.Number(0.0)
    }
    if (precise) {
        significance = abs(significance)
    }
    var mode: Int64 = 0
    if (!precise && args.size > 2) {
        mode = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
    }
    let quotient = x / significance
    var rounded = if (up) { ceil(quotient) } else { floor(quotient) }
    if (!precise && mode != 0 && x < 0.0) {
        rounded = if (up) { floor(quotient) } else { ceil(quotient) }
    }
    CalcValue.Number(rounded * significance)
}

internal func fnBaseConvert(ev: Evaluator, args: Array<Expr>, toBase: Bool): CalcValue {
    if (toBase) {
        let number = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
        let radix = Int64(numberArg(ev, args, 1, 10.0) ?? return CalcValue.Error(CalcError.Value))
        var minLength: Int64 = 0
        if (args.size > 2) {
            minLength = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
        }
        if (radix < 2 || radix > 36 || number < 0.0) {
            return CalcValue.Error(CalcError.Num)
        }
        let text = intToRadix(Int64(number), radix)
        var padded = text
        while (Int64(padded.size) < minLength) {
            padded = "0" + padded
        }
        return CalcValue.Text(padded)
    }
    let text = calcToText(scalarize(ev.arg(args, 0))).trimAscii()
    let radix = Int64(numberArg(ev, args, 1, 10.0) ?? return CalcValue.Error(CalcError.Value))
    if (radix < 2 || radix > 36) {
        return CalcValue.Error(CalcError.Num)
    }
    match (radixToInt(text, radix)) {
        case Some(v) => CalcValue.Number(Float64(v))
        case None => CalcValue.Error(CalcError.Num)
    }
}

private func intToRadix(value: Int64, radix: Int64): String {
    if (value == 0) {
        return "0"
    }
    let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    var n = value
    var out = ""
    while (n > 0) {
        let digit = n % radix
        out = digits[digit..digit + 1] + out
        n = n / radix
    }
    out
}

private func radixToInt(text: String, radix: Int64): ?Int64 {
    if (text.isEmpty()) {
        return None<Int64>
    }
    let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    var value: Int64 = 0
    for (r in text.toAsciiUpper().runes()) {
        let ch = r.toString()
        let index = digits.indexOf(ch) ?? -1
        if (index < 0 || index >= radix) {
            return None<Int64>
        }
        value = value * radix + index
    }
    Some(value)
}

internal func fnBitwise(ev: Evaluator, args: Array<Expr>, mode: String): CalcValue {
    let a = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let b = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let x = Int64(a)
    let y = Int64(b)
    if (x < 0 || y < 0) {
        return CalcValue.Error(CalcError.Num)
    }
    let result = match (mode) {
        case "and" => x & y
        case "or" => x | y
        case "xor" => x ^ y
        case "lshift" =>
            if (y >= 0) {
                x << y
            } else {
                x >> (-y)
            }
        case _ =>
            if (y >= 0) {
                x >> y
            } else {
                x << (-y)
            }
    }
    CalcValue.Number(Float64(result))
}

internal func fnRoman(ev: Evaluator, args: Array<Expr>): CalcValue {
    let number = Int64(numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value))
    if (number < 0 || number > 3999) {
        return CalcValue.Error(CalcError.Value)
    }
    let values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
    let symbols = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
    var remaining = number
    var out = ""
    for (i in 0..values.size) {
        while (remaining >= values[i]) {
            out += symbols[i]
            remaining -= values[i]
        }
    }
    CalcValue.Text(out)
}

internal func fnArabic(ev: Evaluator, args: Array<Expr>): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0))).toAsciiUpper()
    if (text.isEmpty()) {
        return CalcValue.Number(0.0)
    }
    let values = ArrayList<Int64>()
    for (r in text.runes()) {
        let value = match (r) {
            case r'I' => 1
            case r'V' => 5
            case r'X' => 10
            case r'L' => 50
            case r'C' => 100
            case r'D' => 500
            case r'M' => 1000
            case _ => return CalcValue.Error(CalcError.Value)
        }
        values.add(value)
    }
    var total: Int64 = 0
    for (i in 0..values.size) {
        if (i + 1 < values.size && values[i] < values[i + 1]) {
            total -= values[i]
        } else {
            total += values[i]
        }
    }
    CalcValue.Number(Float64(total))
}

internal func fnRandArray(ev: Evaluator, args: Array<Expr>): CalcValue {
    var rows: Int64 = 1
    var cols: Int64 = 1
    var minValue = 0.0
    var maxValue = 1.0
    var whole = false
    if (args.size > 0) {
        rows = Int64(numberArg(ev, args, 0, 1.0) ?? 1.0)
    }
    if (args.size > 1) {
        cols = Int64(numberArg(ev, args, 1, 1.0) ?? 1.0)
    }
    if (args.size > 2) {
        minValue = numberArg(ev, args, 2, 0.0) ?? 0.0
    }
    if (args.size > 3) {
        maxValue = numberArg(ev, args, 3, 1.0) ?? 1.0
    }
    if (args.size > 4) {
        whole = match (calcToBool(scalarize(ev.arg(args, 4)))) {
            case Some(v) => v
            case None => false
        }
    }
    if (rows < 1 || cols < 1 || rows * cols > 1_048_576 || minValue > maxValue) {
        return CalcValue.Error(CalcError.Value)
    }
    let out = ArrayList<Array<CalcValue>>()
    for (_ in 0..rows) {
        let line = ArrayList<CalcValue>()
        for (_ in 0..cols) {
            var value = minValue + ev.nextRandom() * (maxValue - minValue)
            if (whole) {
                value = floor(value)
            }
            line.add(CalcValue.Number(value))
        }
        out.add(line.toArray())
    }
    CalcValue.ArrayValue(out.toArray())
}

// ---------------------------------------------------------------- 工程

private func intBaseConvert(value: Int64, radix: Int64, width: Int64, negativeBits: Int64): String {
    var n = value
    if (n < 0) {
        n = n + (1 << negativeBits)
    }
    let text = intToRadix(n, radix)
    var padded = text
    let target = if (value < 0) { width } else { Int64(padded.size) }
    while (Int64(padded.size) < target) {
        padded = "0" + padded
    }
    padded
}

internal func fnEngBase(ev: Evaluator, args: Array<Expr>, kind: String): CalcValue {
    let text = calcToText(scalarize(ev.arg(args, 0))).trimAscii().toAsciiUpper()
    var fromRadix: Int64 = 10
    match (kind) {
        case "dec2bin" => fromRadix = 10
        case "dec2hex" => fromRadix = 10
        case "dec2oct" => fromRadix = 10
        case "bin2dec" => fromRadix = 2
        case "bin2hex" => fromRadix = 2
        case "bin2oct" => fromRadix = 2
        case "hex2dec" => fromRadix = 16
        case "hex2bin" => fromRadix = 16
        case "hex2oct" => fromRadix = 16
        case "oct2dec" => fromRadix = 8
        case "oct2bin" => fromRadix = 8
        case _ => fromRadix = 8
    }
    var places: Int64 = 0
    if (args.size > 1) {
        places = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    }
    let parsed = match (radixToInt(text, fromRadix)) {
        case Some(v) => v
        case None => return CalcValue.Error(CalcError.Num)
    }
    match (kind) {
        case "dec2bin" => if (parsed < -512 || parsed > 511) {
            return CalcValue.Error(CalcError.Num)
        } else {
            CalcValue.Text(intBaseConvert(parsed, 2, 10, 10))
        }
        case "dec2hex" => if (parsed < -549755813888 || parsed > 549755813887) {
            return CalcValue.Error(CalcError.Num)
        } else {
            CalcValue.Text(intBaseConvert(parsed, 16, 10, 40))
        }
        case "dec2oct" => if (parsed < -536870912 || parsed > 536870911) {
            return CalcValue.Error(CalcError.Num)
        } else {
            CalcValue.Text(intBaseConvert(parsed, 8, 10, 30))
        }
        case "bin2dec" => CalcValue.Number(Float64(parsed))
        case "bin2hex" => CalcValue.Text(intToRadix(parsed, 16))
        case "bin2oct" => CalcValue.Text(intToRadix(parsed, 8))
        case "hex2dec" => CalcValue.Number(Float64(parsed))
        case "hex2bin" => CalcValue.Text(intToRadix(parsed, 2))
        case "hex2oct" => CalcValue.Text(intToRadix(parsed, 8))
        case "oct2dec" => CalcValue.Number(Float64(parsed))
        case "oct2bin" => CalcValue.Text(intToRadix(parsed, 2))
        case _ => CalcValue.Text(intToRadix(parsed, 16))
    }
}

internal func fnDeltaStep(ev: Evaluator, args: Array<Expr>, delta: Bool): CalcValue {
    let a = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let b = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let hit = if (delta) { a == b } else { a >= b }
    CalcValue.Number(if (hit) { 1.0 } else { 0.0 })
}

internal func fnErf(ev: Evaluator, args: Array<Expr>, complement: Bool): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let value = if (complement) { 1.0 - erf(x) } else { erf(x) }
    CalcValue.Number(value)
}
