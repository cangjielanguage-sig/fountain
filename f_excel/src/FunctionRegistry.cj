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

internal type FnImpl = (Evaluator, Array<Expr>) -> CalcValue

/** 函数注册项：`maxArgs = -1` 表示可变参数。 */
internal struct FnEntry {
    public let name: String
    public let minArgs: Int64
    public let maxArgs: Int64
    public let impl: FnImpl

    public init(name: String, minArgs: Int64, maxArgs: Int64, impl: FnImpl) {
        this.name = name
        this.minArgs = minArgs
        this.maxArgs = maxArgs
        this.impl = impl
    }
}

/** 按名查找（大小写不敏感）；未注册返回 `None`。 */
internal func lookupFunction(rawName: String): ?FnEntry {
    let name = rawName.toAsciiUpper()
    match (name) {
        // 数学
        case "SUM" => Some(FnEntry(name, 1, -1, { ev, args => fnSum(ev, args) }))
        case "PRODUCT" => Some(FnEntry(name, 1, -1, { ev, args => fnProduct(ev, args) }))
        case "ABS" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "abs") }))
        case "SIGN" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "sign") }))
        case "SQRT" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "sqrt") }))
        case "INT" => Some(FnEntry(name, 1, 1, { ev, args => fnUnaryMath(ev, args, "int") }))
        case "ROUND" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "round") }))
        case "ROUNDUP" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "up") }))
        case "ROUNDDOWN" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "down") }))
        case "TRUNC" => Some(FnEntry(name, 1, 2, { ev, args => fnRound(ev, args, "down") }))
        case "MOD" => Some(FnEntry(name, 2, 2, { ev, args => fnMod(ev, args) }))
        case "POWER" => Some(FnEntry(name, 2, 2, { ev, args => fnPower(ev, args) }))
        case "SUMIF" => Some(FnEntry(name, 2, 3, { ev, args => fnSumIf(ev, args) }))
        case "SUMIFS" => Some(FnEntry(name, 3, -1, { ev, args => fnSumIfs(ev, args) }))
        // 统计
        case "AVERAGE" => Some(FnEntry(name, 1, -1, { ev, args => fnAverage(ev, args) }))
        case "AVERAGEIF" => Some(FnEntry(name, 2, 3, { ev, args => fnAverageIf(ev, args) }))
        case "COUNT" => Some(FnEntry(name, 1, -1, { ev, args => fnCount(ev, args) }))
        case "COUNTA" => Some(FnEntry(name, 1, -1, { ev, args => fnCountA(ev, args) }))
        case "COUNTBLANK" => Some(FnEntry(name, 1, 1, { ev, args => fnCountBlank(ev, args) }))
        case "COUNTIF" => Some(FnEntry(name, 2, 2, { ev, args => fnCountIf(ev, args) }))
        case "COUNTIFS" => Some(FnEntry(name, 2, -1, { ev, args => fnCountIfs(ev, args) }))
        case "MIN" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMax(ev, args, true) }))
        case "MAX" => Some(FnEntry(name, 1, -1, { ev, args => fnMinMax(ev, args, false) }))
        case "MEDIAN" => Some(FnEntry(name, 1, -1, { ev, args => fnMedian(ev, args) }))
        // 逻辑
        case "IF" => Some(FnEntry(name, 1, 3, { ev, args => fnIf(ev, args) }))
        case "IFS" => Some(FnEntry(name, 2, -1, { ev, args => fnIfs(ev, args) }))
        case "AND" => Some(FnEntry(name, 1, -1, { ev, args => fnAndOr(ev, args, true) }))
        case "OR" => Some(FnEntry(name, 1, -1, { ev, args => fnAndOr(ev, args, false) }))
        case "NOT" => Some(FnEntry(name, 1, 1, { ev, args => fnNot(ev, args) }))
        case "XOR" => Some(FnEntry(name, 1, -1, { ev, args => fnXor(ev, args) }))
        case "IFERROR" => Some(FnEntry(name, 2, 2, { ev, args => fnIfError(ev, args, false) }))
        case "IFNA" => Some(FnEntry(name, 2, 2, { ev, args => fnIfError(ev, args, true) }))
        case "SWITCH" => Some(FnEntry(name, 3, -1, { ev, args => fnSwitch(ev, args) }))
        // 文本
        case "CONCATENATE" => Some(FnEntry(name, 1, -1, { ev, args => fnConcat(ev, args) }))
        case "CONCAT" => Some(FnEntry(name, 1, -1, { ev, args => fnConcat(ev, args) }))
        case "LEN" => Some(FnEntry(name, 1, 1, { ev, args => fnLen(ev, args) }))
        case "LEFT" => Some(FnEntry(name, 1, 2, { ev, args => fnLeftRight(ev, args, true) }))
        case "RIGHT" => Some(FnEntry(name, 1, 2, { ev, args => fnLeftRight(ev, args, false) }))
        case "MID" => Some(FnEntry(name, 3, 3, { ev, args => fnMid(ev, args) }))
        case "TRIM" => Some(FnEntry(name, 1, 1, { ev, args => fnTrim(ev, args) }))
        case "UPPER" => Some(FnEntry(name, 1, 1, { ev, args => fnCase(ev, args, true) }))
        case "LOWER" => Some(FnEntry(name, 1, 1, { ev, args => fnCase(ev, args, false) }))
        case "TEXT" => Some(FnEntry(name, 2, 2, { ev, args => fnText(ev, args) }))
        case "VALUE" => Some(FnEntry(name, 1, 1, { ev, args => fnValue(ev, args) }))
        // 日期
        case "DATE" => Some(FnEntry(name, 3, 3, { ev, args => fnDate(ev, args) }))
        case "YEAR" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "year") }))
        case "MONTH" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "month") }))
        case "DAY" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "day") }))
        case "HOUR" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "hour") }))
        case "MINUTE" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "minute") }))
        case "SECOND" => Some(FnEntry(name, 1, 1, { ev, args => fnDatePart(ev, args, "second") }))
        case "TODAY" => Some(FnEntry(name, 0, 0, { ev, args => CalcValue.Number(ev.todaySerial()) }))
        case "NOW" => Some(FnEntry(name, 0, 0, { ev, args => CalcValue.Number(ev.nowSerial()) }))
        // 查找
        case "VLOOKUP" => Some(FnEntry(name, 3, 4, { ev, args => fnVLookup(ev, args) }))
        case "INDEX" => Some(FnEntry(name, 2, 3, { ev, args => fnIndex(ev, args) }))
        case "MATCH" => Some(FnEntry(name, 2, 3, { ev, args => fnMatch(ev, args) }))
        // 信息
        case "ISBLANK" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "blank") }))
        case "ISERROR" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "error") }))
        case "ISNUMBER" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "number") }))
        case "ISTEXT" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "text") }))
        case "ISLOGICAL" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "logical") }))
        case "ISNA" => Some(FnEntry(name, 1, 1, { ev, args => fnIsType(ev, args, "na") }))
        case _ => None<FnEntry>
    }
}

/** 当前注册的函数个数（测试用）。 */
internal let CORE_FUNCTION_NAMES: Array<String> = [
    "SUM", "PRODUCT", "ABS", "SIGN", "SQRT", "INT", "ROUND", "ROUNDUP", "ROUNDDOWN", "TRUNC",
    "MOD", "POWER", "SUMIF", "SUMIFS", "AVERAGE", "AVERAGEIF", "COUNT", "COUNTA", "COUNTBLANK",
    "COUNTIF", "COUNTIFS", "MIN", "MAX", "MEDIAN", "IF", "IFS", "AND", "OR", "NOT", "XOR",
    "IFERROR", "IFNA", "SWITCH", "CONCATENATE", "CONCAT", "LEN", "LEFT", "RIGHT", "MID", "TRIM",
    "UPPER", "LOWER", "TEXT", "VALUE", "DATE", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
    "TODAY", "NOW", "VLOOKUP", "INDEX", "MATCH", "ISBLANK", "ISERROR", "ISNUMBER", "ISTEXT",
    "ISLOGICAL", "ISNA"
]

// ---------------------------------------------------------------- 实参辅助

/** 一批实参里的数字：区域只取数字（忽略文本/布尔/空），标量允许隐式转换。 */
internal func numbersOf(ev: Evaluator, args: Array<Expr>, index: Int64): (ArrayList<Float64>, ?CalcError) {
    let out = ArrayList<Float64>()
    let value = ev.arg(args, index)
    match (value) {
        case Error(e) => return (out, Some(e))
        case ArrayValue(rows) =>
            for (row in rows) {
                for (item in row) {
                    match (item) {
                        case Number(v) => out.add(v)
                        case Error(e) => return (out, Some(e))
                        case _ => ()
                    }
                }
            }
        case Empty => ()
        case _ => match (calcToNumber(value)) {
            case Some(v) => out.add(v)
            case None => return (out, Some(CalcError.Value))
        }
    }
    (out, None<CalcError>)
}

/** 展平一个实参（区域 → 全部标量）。 */
internal func scalarsOf(ev: Evaluator, args: Array<Expr>, index: Int64): ArrayList<CalcValue> {
    flattenValues(ev.arg(args, index))
}

/** 判定一个值是否满足条件（`">3"`、`"<>x"`、`"a*"` 仅支持前两种与相等）。 */
internal func criteriaMatch(value: CalcValue, criteria: CalcValue): Bool {
    let item = scalarize(value)
    match (criteria) {
        case Text(raw) =>
            let text = raw
            let ops = [">=", "<=", "<>", ">", "<", "="]
            var op = ""
            var rest = text
            for (candidate in ops) {
                if (text.startsWith(candidate)) {
                    op = candidate
                    rest = text[candidate.size..]
                    break
                }
            }
            if (op.isEmpty()) {
                return compareCalc(item, CalcValue.Text(text)) == Some(0)
            }
            let rhs = if (isNumericText(rest)) {
                CalcValue.Number(parseNumberText(rest).getOrThrow())
            } else {
                CalcValue.Text(rest)
            }
            let order = match (compareCalc(item, rhs)) {
                case Some(v) => v
                case None => return false
            }
            match (op) {
                case ">=" => order >= 0
                case "<=" => order <= 0
                case "<>" => order != 0
                case ">" => order > 0
                case "<" => order < 0
                case _ => order == 0
            }
        case _ => compareCalc(item, criteria) == Some(0)
    }
}

internal func isNumericText(text: String): Bool {
    parseNumberText(text).isSome()
}

/** 按行优先遍历一个区域的标量（含空）。 */
internal func gridOf(value: CalcValue): Array<Array<CalcValue>> {
    match (value) {
        case ArrayValue(rows) => rows
        case Empty => Array<Array<CalcValue>>()
        case _ => [[value]]
    }
}
