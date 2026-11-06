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

private let SQRT2: Float64 = 1.4142135623730951
private let INV_SQRT_2PI: Float64 = 0.3989422804014327

/** 标准正态 CDF。 */
private func normalCdf(z: Float64): Float64 {
    0.5 * (1.0 + erf(z / SQRT2))
}

/** 标准正态 PDF。 */
private func normalPdf(z: Float64): Float64 {
    INV_SQRT_2PI * exp(-0.5 * z * z)
}

/** Acklam 逆正态近似。 */
private func normalInv(p: Float64): Float64 {
    if (p <= 0.0 || p >= 1.0) {
        return 0.0
    }
    let a = [-39.69683028665376, 220.9460984245205, -275.9285104469687, 138.3577518672690, -30.66479806614716, 2.506628277459239]
    let b = [-54.47609879822406, 161.5858368580409, -155.6989798598866, 66.80131188771972, -13.28068155288572]
    let c = [-0.007784894002430293, -0.3223964580411365, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783]
    let d = [0.007784695709041462, 0.3224671290700398, 2.445134137142996, 3.754408661907416]
    let plow = 0.02425
    let phigh = 1.0 - plow
    if (p < plow) {
        let q = sqrt(-2.0 * log(p))
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0)
    }
    if (p <= phigh) {
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
            (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0)
    }
    let q = sqrt(-2.0 * log(1.0 - p))
    -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0)
}

internal func fnNormalDist(ev: Evaluator, args: Array<Expr>, standard: Bool): CalcValue {
    var x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    var mean = 0.0
    var sd = 1.0
    var cumulativeIndex: Int64 = 1
    if (standard) {
        cumulativeIndex = 1
    } else {
        mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
        sd = numberArg(ev, args, 2, 1.0) ?? return CalcValue.Error(CalcError.Value)
        cumulativeIndex = 3
    }
    if (sd <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var cumulative = true
    if (args.size > cumulativeIndex) {
        cumulative = match (calcToBool(scalarize(ev.arg(args, cumulativeIndex)))) {
            case Some(v) => v
            case None => true
        }
    }
    if (standard) {
        if (cumulative) {
            return CalcValue.Number(normalCdf(x))
        }
        return CalcValue.Number(normalPdf(x))
    }
    let z = (x - mean) / sd
    if (cumulative) {
        CalcValue.Number(normalCdf(z))
    } else {
        CalcValue.Number(normalPdf(z) / sd)
    }
}

internal func fnNormalInv(ev: Evaluator, args: Array<Expr>, standard: Bool): CalcValue {
    let p = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (p <= 0.0 || p >= 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (standard) {
        return CalcValue.Number(normalInv(p))
    }
    let mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let sd = numberArg(ev, args, 2, 1.0) ?? return CalcValue.Error(CalcError.Value)
    if (sd <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(mean + sd * normalInv(p))
}

internal func fnLogNormalDist(ev: Evaluator, args: Array<Expr>, inverse: Bool): CalcValue {
    if (inverse) {
        let p = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
        if (p <= 0.0 || p >= 1.0) {
            return CalcValue.Error(CalcError.Num)
        }
        let mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
        let sd = numberArg(ev, args, 2, 1.0) ?? return CalcValue.Error(CalcError.Value)
        return CalcValue.Number(exp(mean + sd * normalInv(p)))
    }
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let sd = numberArg(ev, args, 2, 1.0) ?? return CalcValue.Error(CalcError.Value)
    var cumulative = true
    if (args.size > 3) {
        cumulative = match (calcToBool(scalarize(ev.arg(args, 3)))) {
            case Some(v) => v
            case None => true
        }
    }
    if (x <= 0.0 || sd <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let z = (log(x) - mean) / sd
    if (cumulative) {
        CalcValue.Number(normalCdf(z))
    } else {
        CalcValue.Number(normalPdf(z) / (x * sd))
    }
}

internal func fnExponDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let lambda = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 2)))) {
        case Some(v) => v
        case None => true
    }
    if (x < 0.0 || lambda <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (cumulative) {
        CalcValue.Number(1.0 - exp(-lambda * x))
    } else {
        CalcValue.Number(lambda * exp(-lambda * x))
    }
}

private func combination(n: Int64, k: Int64): Float64 {
    if (k < 0 || k > n) {
        return 0.0
    }
    var result = 1.0
    var i: Int64 = 1
    while (i <= k) {
        result = result * Float64(n - k + i) / Float64(i)
        i++
    }
    floor(result + 0.5)
}

internal func fnPoissonDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let mean = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 2)))) {
        case Some(v) => v
        case None => true
    }
    if (x < 0 || mean < 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    let pmf = exp(-mean) * pow(mean, Float64(x)) / factorialOf(x)
    if (cumulative) {
        var total = 0.0
        var k: Int64 = 0
        while (k <= x) {
            total += exp(-mean) * pow(mean, Float64(k)) / factorialOf(k)
            k++
        }
        return CalcValue.Number(total)
    }
    CalcValue.Number(pmf)
}

private func factorialOf(n: Int64): Float64 {
    var result = 1.0
    var i: Int64 = 2
    while (i <= n) {
        result *= Float64(i)
        i++
    }
    result
}

internal func fnBinomDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let k = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let n = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    let p = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 3)))) {
        case Some(v) => v
        case None => true
    }
    if (k < 0 || n < 0 || k > n || p < 0.0 || p > 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (cumulative) {
        var total = 0.0
        var i: Int64 = 0
        while (i <= k) {
            total += combination(n, i) * pow(p, Float64(i)) * pow(1.0 - p, Float64(n - i))
            i++
        }
        return CalcValue.Number(total)
    }
    CalcValue.Number(combination(n, k) * pow(p, Float64(k)) * pow(1.0 - p, Float64(n - k)))
}

internal func fnBinomInv(ev: Evaluator, args: Array<Expr>): CalcValue {
    let n = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let p = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let alpha = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (n < 0 || p < 0.0 || p > 1.0 || alpha < 0.0 || alpha > 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    var cumulative = 0.0
    var k: Int64 = 0
    while (k <= n) {
        cumulative += combination(n, k) * pow(p, Float64(k)) * pow(1.0 - p, Float64(n - k))
        if (cumulative >= alpha) {
            return CalcValue.Number(Float64(k))
        }
        k++
    }
    CalcValue.Number(Float64(n))
}

internal func fnNegBinomDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let failures = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let successes = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    let p = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 3)))) {
        case Some(v) => v
        case None => true
    }
    if (failures < 0 || successes < 1 || p <= 0.0 || p > 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (cumulative) {
        var total = 0.0
        var f: Int64 = 0
        while (f <= failures) {
            total += combination(f + successes - 1, f) * pow(p, Float64(successes)) * pow(1.0 - p, Float64(f))
            f++
        }
        return CalcValue.Number(total)
    }
    CalcValue.Number(
        combination(failures + successes - 1, failures) * pow(p, Float64(successes)) *
            pow(1.0 - p, Float64(failures))
    )
}

internal func fnHypGeomDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let k = Int64(numberArg(ev, args, 0, 0.0) ?? 0.0)
    let n = Int64(numberArg(ev, args, 1, 0.0) ?? 0.0)
    let successes = Int64(numberArg(ev, args, 2, 0.0) ?? 0.0)
    let population = Int64(numberArg(ev, args, 3, 0.0) ?? 0.0)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 4)))) {
        case Some(v) => v
        case None => true
    }
    if (k < 0 || n < 0 || successes < 0 || population < 1 || n > population || successes > population) {
        return CalcValue.Error(CalcError.Num)
    }
    if (cumulative) {
        var total = 0.0
        var i: Int64 = 0
        while (i <= k) {
            total += combination(successes, i) * combination(population - successes, n - i) /
                combination(population, n)
            i++
        }
        return CalcValue.Number(total)
    }
    CalcValue.Number(
        combination(successes, k) * combination(population - successes, n - k) / combination(population, n)
    )
}

internal func fnWeibullDist(ev: Evaluator, args: Array<Expr>): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let alpha = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let beta = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let cumulative = match (calcToBool(scalarize(ev.arg(args, 3)))) {
        case Some(v) => v
        case None => true
    }
    if (x < 0.0 || alpha <= 0.0 || beta <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (cumulative) {
        CalcValue.Number(1.0 - exp(-pow(x / beta, alpha)))
    } else {
        CalcValue.Number(
            alpha / pow(beta, alpha) * pow(x, alpha - 1.0) * exp(-pow(x / beta, alpha))
        )
    }
}

internal func fnGamma(ev: Evaluator, args: Array<Expr>, logMode: Bool): CalcValue {
    let x = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (x <= 0.0) {
        return CalcValue.Error(CalcError.Num)
    }
    if (logMode) {
        CalcValue.Number(log(gamma(x)))
    } else {
        CalcValue.Number(gamma(x))
    }
}

internal func fnConfidenceNorm(ev: Evaluator, args: Array<Expr>): CalcValue {
    let alpha = numberArg(ev, args, 0, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let sd = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    let n = numberArg(ev, args, 2, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (alpha <= 0.0 || alpha >= 1.0 || sd <= 0.0 || n < 1.0) {
        return CalcValue.Error(CalcError.Num)
    }
    CalcValue.Number(normalInv(1.0 - alpha / 2.0) * sd / sqrt(n))
}

internal func fnZTest(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = numbersOf(ev, args, 0)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let x = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    var mean = 0.0
    for (v in values) {
        mean += v
    }
    mean /= Float64(values.size)
    var sigma = 0.0
    if (args.size > 2) {
        sigma = numberArg(ev, args, 2, 0.0) ?? 0.0
    } else {
        var total = 0.0
        for (v in values) {
            total += (v - mean) * (v - mean)
        }
        sigma = sqrt(total / Float64(values.size - 1))
    }
    if (sigma <= 0.0) {
        return CalcValue.Error(CalcError.DivZero)
    }
    CalcValue.Number(1.0 - normalCdf((mean - x) / (sigma / sqrt(Float64(values.size)))))
}

internal func fnPercentileExc(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (values, error) = sortedNumbers(ev, [args[0]])
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let k = numberArg(ev, args, 1, 0.0) ?? return CalcValue.Error(CalcError.Value)
    if (k <= 0.0 || k >= 1.0 || values.size == 0) {
        return CalcValue.Error(CalcError.Num)
    }
    let position = k * Float64(values.size + 1)
    if (position < 1.0 || position > Float64(values.size)) {
        return CalcValue.Error(CalcError.Num)
    }
    let lower = Int64(floor(position)) - 1
    let upper = if (lower + 1 < values.size) { lower + 1 } else { lower }
    let fraction = position - floor(position)
    CalcValue.Number(values[lower] + (values[upper] - values[lower]) * fraction)
}

internal func fnFrequency(ev: Evaluator, args: Array<Expr>): CalcValue {
    let (data, error) = numbersOf(ev, args, 0)
    match (error) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let (bins, binError) = numbersOf(ev, args, 1)
    match (binError) {
        case Some(e) => return CalcValue.Error(e)
        case None => ()
    }
    let counts = ArrayList<Int64>()
    for (_ in 0..(bins.size + 1)) {
        counts.add(0)
    }
    for (value in data) {
        var placed = false
        for (i in 0..bins.size) {
            if (value <= bins[i]) {
                counts[i] = counts[i] + 1
                placed = true
                break
            }
        }
        if (!placed) {
            counts[bins.size] = counts[bins.size] + 1
        }
    }
    let rows = ArrayList<Array<CalcValue>>()
    for (count in counts) {
        rows.add([CalcValue.Number(Float64(count))])
    }
    CalcValue.ArrayValue(rows.toArray())
}
