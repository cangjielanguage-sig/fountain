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

/** 条件格式求值（M4-b/c/d）。 */
internal func cfRuleHit(
    rule: CfRule,
    value: CalcValue,
    rangeValues: ArrayList<CalcValue>,
    sheet: String,
    ref: CellRef,
    expression: ?(String) -> CalcValue
): ?CfFormat {
    match (rule.ruleType) {
        case CellIs => return cfCellIs(rule, value)
        case ContainsText => return cfTextRule(rule, value, "contains")
        case NotContainsText => return cfTextRule(rule, value, "notContains")
        case BeginsWith => return cfTextRule(rule, value, "begins")
        case EndsWith => return cfTextRule(rule, value, "ends")
        case ContainsBlanks => return match (value) {
            case Empty => Some(rule.format ?? CfFormat())
            case _ => None<CfFormat>
        }
        case NotContainsBlanks => return match (value) {
            case Empty => None<CfFormat>
            case _ => Some(rule.format ?? CfFormat())
        }
        case ContainsErrors => return match (value) {
            case Error(_) => Some(rule.format ?? CfFormat())
            case _ => None<CfFormat>
        }
        case NotContainsErrors => return match (value) {
            case Error(_) => None<CfFormat>
            case _ => Some(rule.format ?? CfFormat())
        }
        case Top10 => return cfTop10(rule, value, rangeValues)
        case DuplicateValues => return cfDuplicate(rule, value, rangeValues, true)
        case UniqueValues => return cfDuplicate(rule, value, rangeValues, false)
        case ColorScale => return cfColorScale(rule, value, rangeValues)
        case DataBar => return cfDataBar(rule, value, rangeValues)
        case IconSet => return cfIconSet(rule, value, rangeValues)
        case Expression =>
            return match (expression) {
                case Some(eval) => if (rule.formulas.size == 0) {
                    None<CfFormat>
                } else {
                    let result = eval(rule.formulas[0])
                    match (calcToBool(result)) {
                        case Some(true) => Some(rule.format ?? CfFormat())
                        case _ => None<CfFormat>
                    }
                }
                case None => None<CfFormat>
            }
        case _ => return None<CfFormat>
    }
}

private func cfCellIs(rule: CfRule, value: CalcValue): ?CfFormat {
    let cell = scalarize(value)
    if (rule.formulas.size == 0) {
        return None<CfFormat>
    }
    let target = match (parseNumberText(rule.formulas[0])) {
        case Some(v) => CalcValue.Number(v)
        case None => CalcValue.Text(rule.formulas[0])
    }
    let order = match (compareCalc(cell, target)) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let hit = match (rule.comparison) {
        case LessThan => order < 0
        case LessThanOrEqual => order <= 0
        case Equal => order == 0
        case NotEqual => order != 0
        case GreaterThanOrEqual => order >= 0
        case GreaterThan => order > 0
        case Between =>
            if (rule.formulas.size > 1) {
                let upper = match (parseNumberText(rule.formulas[1])) {
                    case Some(v) => CalcValue.Number(v)
                    case None => CalcValue.Text(rule.formulas[1])
                }
                order >= 0 && (compareCalc(cell, upper) ?? 1) <= 0
            } else {
                false
            }
        case NotBetween =>
            if (rule.formulas.size > 1) {
                let upper = match (parseNumberText(rule.formulas[1])) {
                    case Some(v) => CalcValue.Number(v)
                    case None => CalcValue.Text(rule.formulas[1])
                }
                order < 0 || (compareCalc(cell, upper) ?? 0) > 0
            } else {
                false
            }
        case NoOperator => false
    }
    if (hit) {
        Some(rule.format ?? CfFormat())
    } else {
        None<CfFormat>
    }
}

private func cfTextRule(rule: CfRule, value: CalcValue, mode: String): ?CfFormat {
    let text = calcToText(scalarize(value)).toAsciiLower()
    let needle = (match (rule.text) {
        case Some(v) => v
        case None => if (rule.formulas.size > 0) {
            rule.formulas[0]
        } else {
            ""
        }
    }).toAsciiLower()
    let hit = match (mode) {
        case "contains" => text.contains(needle)
        case "notContains" => !text.contains(needle)
        case "begins" => text.startsWith(needle)
        case _ => text.endsWith(needle)
    }
    if (hit) {
        Some(rule.format ?? CfFormat())
    } else {
        None<CfFormat>
    }
}

private func numericValues(values: ArrayList<CalcValue>): ArrayList<Float64> {
    let result = ArrayList<Float64>()
    for (item in values) {
        match (item) {
            case Number(v) => result.add(v)
            case _ => ()
        }
    }
    result
}

private func cfTop10(rule: CfRule, value: CalcValue, rangeValues: ArrayList<CalcValue>): ?CfFormat {
    let numbers = numericValues(rangeValues)
    let current = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    var count: Int64 = 10
    if (rule.formulas.size > 0) {
        count = match (parseNumberText(rule.formulas[0])) {
            case Some(v) => Int64(v)
            case None => 10
        }
    }
    if (count < 1) {
        count = 1
    }
    var rank: Int64 = 1
    for (v in numbers) {
        if (v > current) {
            rank++
        }
    }
    if (rank <= count) {
        Some(rule.format ?? CfFormat())
    } else {
        None<CfFormat>
    }
}

private func cfDuplicate(
    rule: CfRule,
    value: CalcValue,
    rangeValues: ArrayList<CalcValue>,
    duplicates: Bool
): ?CfFormat {
    let cell = scalarize(value)
    if (match (cell) {
        case Empty => true
        case _ => false
    }) {
        return None<CfFormat>
    }
    var count: Int64 = 0
    for (item in rangeValues) {
        if (compareCalc(scalarize(item), cell) == Some(0)) {
            count++
        }
    }
    let hit = if (duplicates) { count > 1 } else { count == 1 }
    if (hit) {
        Some(rule.format ?? CfFormat())
    } else {
        None<CfFormat>
    }
}

private func cfColorScale(rule: CfRule, value: CalcValue, rangeValues: ArrayList<CalcValue>): ?CfFormat {
    let scale = match (rule.colorScale) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    if (scale.colors.size == 0) {
        return None<CfFormat>
    }
    let current = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let numbers = numericValues(rangeValues)
    if (numbers.size == 0) {
        return None<CfFormat>
    }
    let minValue = cfThreshold(scale.cfvos, 0, numbers, true)
    let maxValue = cfThreshold(scale.cfvos, scale.cfvos.size - 1, numbers, false)
    let color = if (scale.colors.size == 2) {
        let fraction = fractionOf(current, minValue, maxValue)
        interpolateColor(scale.colors[0], scale.colors[1], fraction)
    } else {
        let midValue = cfThreshold(scale.cfvos, 1, numbers, false)
        if (current <= midValue) {
            let fraction = fractionOf(current, minValue, midValue)
            interpolateColor(scale.colors[0], scale.colors[1], fraction)
        } else {
            let fraction = fractionOf(current, midValue, maxValue)
            interpolateColor(scale.colors[1], scale.colors[scale.colors.size - 1], fraction)
        }
    }
    Some(CfFormat(fill: Some(color)))
}

private func cfThreshold(
    cfvos: ArrayList<Cfvo>,
    index: Int64,
    numbers: ArrayList<Float64>,
    fallbackMin: Bool
): Float64 {
    var sorted = ArrayList<Float64>()
    for (v in numbers) {
        sorted.add(v)
    }
    for (i in 1..sorted.size) {
        let key = sorted[i]
        var j = i - 1
        while (j >= 0 && sorted[j] > key) {
            sorted[j + 1] = sorted[j]
            j--
        }
        sorted[j + 1] = key
    }
    let minValue = sorted[0]
    let maxValue = sorted[sorted.size - 1]
    if (index < 0 || index >= cfvos.size) {
        return if (fallbackMin) { minValue } else { maxValue }
    }
    let cfvo = cfvos[index]
    match (cfvo.kind) {
        case "min" => minValue
        case "max" => maxValue
        case "percent" =>
            let p = (parseNumberText(cfvo.value) ?? 0.0) / 100.0
            minValue + (maxValue - minValue) * p
        case "percentile" =>
            let p = (parseNumberText(cfvo.value) ?? 0.0) / 100.0
            let position = p * Float64(sorted.size - 1)
            let lower = Int64(position)
            let upper = if (lower + 1 < sorted.size) { lower + 1 } else { lower }
            let fraction = position - Float64(lower)
            sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        case "num" | "formula" => parseNumberText(cfvo.value) ?? minValue
        case _ => if (fallbackMin) { minValue } else { maxValue }
    }
}

private func fractionOf(value: Float64, minValue: Float64, maxValue: Float64): Float64 {
    if (maxValue <= minValue) {
        return 0.0
    }
    let fraction = (value - minValue) / (maxValue - minValue)
    if (fraction < 0.0) {
        0.0
    } else if (fraction > 1.0) {
        1.0
    } else {
        fraction
    }
}

private func parseColor(value: String): (Int64, Int64, Int64) {
    var body = value
    if (body.startsWith("#")) {
        body = body[1..]
    }
    if (body.size == 8) {
        body = body[2..]
    }
    if (body.size != 6) {
        return (0, 0, 0)
    }
    (hexByte(body, 0), hexByte(body, 2), hexByte(body, 4))
}

private func hexByte(text: String, offset: Int64): Int64 {
    let bytes = text.toArray()
    var value: Int64 = 0
    for (i in offset..offset + 2) {
        let ch = bytes[i]
        let digit = if (ch >= 48u8 && ch <= 57u8) {
            Int64(ch - 48u8)
        } else if (ch >= 65u8 && ch <= 70u8) {
            Int64(ch - 65u8) + 10
        } else if (ch >= 97u8 && ch <= 102u8) {
            Int64(ch - 97u8) + 10
        } else {
            0
        }
        value = value * 16 + digit
    }
    value
}

private func interpolateColor(left: String, right: String, fraction: Float64): String {
    let (lr, lg, lb) = parseColor(left)
    let (rr, rg, rb) = parseColor(right)
    let r = Int64(Float64(lr) + (Float64(rr - lr) * fraction))
    let g = Int64(Float64(lg) + (Float64(rg - lg) * fraction))
    let b = Int64(Float64(lb) + (Float64(rb - lb) * fraction))
    "FF" + hex2(r) + hex2(g) + hex2(b)
}

private func hex2(value: Int64): String {
    let digits = "0123456789ABCDEF"
    let high = (value / 16) % 16
    let low = value % 16
    digits[high..high + 1] + digits[low..low + 1]
}

private func cfDataBar(rule: CfRule, value: CalcValue, rangeValues: ArrayList<CalcValue>): ?CfFormat {
    let bar = match (rule.dataBar) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let current = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let numbers = numericValues(rangeValues)
    if (numbers.size == 0) {
        return None<CfFormat>
    }
    let minList = ArrayList<Cfvo>()
    minList.add(bar.min)
    let maxList = ArrayList<Cfvo>()
    maxList.add(bar.max)
    let minValue = cfThreshold(minList, 0, numbers, true)
    let maxValue = cfThreshold(maxList, 0, numbers, false)
    Some(CfFormat(dataBarLength: fractionOf(current, minValue, maxValue)))
}

private func cfIconSet(rule: CfRule, value: CalcValue, rangeValues: ArrayList<CalcValue>): ?CfFormat {
    let set = match (rule.iconSet) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let current = match (calcToNumber(scalarize(value))) {
        case Some(v) => v
        case None => return None<CfFormat>
    }
    let numbers = numericValues(rangeValues)
    if (numbers.size == 0) {
        return None<CfFormat>
    }
    var index: Int64 = 0
    for (i in 0..set.cfvos.size) {
        let threshold = cfThreshold(set.cfvos, i, numbers, true)
        if (current >= threshold) {
            index = i
        }
    }
    Some(CfFormat(icon: "${set.name}:${index}"))
}
