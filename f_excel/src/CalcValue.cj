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
import std.time.DateTime

/** 公式求值的错误值。文本形式与 Excel 一致。 */
public enum CalcError <: Equatable<CalcError> & ToString {
    | Null
    | DivZero
    | Value
    | Ref
    | Name
    | Num
    | NotAvailable
    | GettingData
    | Circular
    | Spill

    public operator func ==(that: CalcError): Bool {
        this.toString() == that.toString()
    }

    public operator func !=(that: CalcError): Bool {
        !(this == that)
    }

    public func toString(): String {
        match (this) {
            case Null => "#NULL!"
            case DivZero => "#DIV/0!"
            case Value => "#VALUE!"
            case Ref => "#REF!"
            case Name => "#NAME?"
            case Num => "#NUM!"
            case NotAvailable => "#N/A"
            case GettingData => "#GETTING_DATA"
            case Circular => "#CIRC!"
            case Spill => "#SPILL!"
        }
    }

    /** 解析 `#DIV/0!` 之类文本；不是错误值返回 `None`。 */
    public static func parse(text: String): ?CalcError {
        match (text.toAsciiUpper()) {
            case "#NULL!" => Some(Null)
            case "#DIV/0!" => Some(DivZero)
            case "#VALUE!" => Some(Value)
            case "#REF!" => Some(Ref)
            case "#NAME?" => Some(Name)
            case "#NUM!" => Some(Num)
            case "#N/A" => Some(NotAvailable)
            case "#GETTING_DATA" => Some(GettingData)
            case "#CIRC!" => Some(Circular)
            case "#SPILL!" => Some(Spill)
            case _ => None<CalcError>
        }
    }
}

/**
 * 公式值模型（设计 7.4）。
 *
 * 与 [CellValue] 的区别：这里的日期一律是**序列号**（数值），因为公式只认数字；
 * `Array` 分支叫 `ArrayValue`，避免与内置 `Array` 类型重名。
 */
public enum CalcValue <: ToString {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(CalcError)
    | ArrayValue(Array<Array<CalcValue>>)

    public func toString(): String {
        match (this) {
            case Empty => ""
            case Number(v) => formatNumber(v)
            case Text(v) => v
            case Boolean(v) => if (v) { "TRUE" } else { "FALSE" }
            case Error(v) => v.toString()
            case ArrayValue(rows) =>
                if (rows.size == 0) {
                    ""
                } else if (rows[0].size == 0) {
                    ""
                } else {
                    rows[0][0].toString()
                }
        }
    }

    public func isError(): Bool {
        match (this) {
            case Error(_) => true
            case _ => false
        }
    }

    public func asError(): ?CalcError {
        match (this) {
            case Error(e) => Some(e)
            case _ => None<CalcError>
        }
    }
}

// ---------------------------------------------------------------- 转换

/** 隐式数值转换（设计 7.4.1）：空 → 0、布尔 → 0/1、数字文本 → 数字。 */
internal func calcToNumber(value: CalcValue): ?Float64 {
    match (value) {
        case Empty => Some(0.0)
        case Number(v) => Some(v)
        case Boolean(v) => Some(if (v) { 1.0 } else { 0.0 })
        case Text(text) => parseNumberText(text)
        case Error(_) => None<Float64>
        case ArrayValue(rows) =>
            if (rows.size == 1 && rows[0].size == 1) {
                calcToNumber(rows[0][0])
            } else if (rows.size == 0 || rows[0].size == 0) {
                Some(0.0)
            } else {
                None<Float64>
            }
    }
}

internal func parseNumberText(text: String): ?Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.isEmpty()) {
        return None<Float64>
    }
    try {
        Some(Float64.parse(trimmed))
    } catch (_: Exception) {
        None<Float64>
    }
}

/** 隐式文本转换：空 → `""`、数字 → 最短往返串、布尔 → TRUE/FALSE。 */
internal func calcToText(value: CalcValue): String {
    match (value) {
        case Empty => ""
        case Number(v) => formatNumber(v)
        case Text(v) => v
        case Boolean(v) => if (v) { "TRUE" } else { "FALSE" }
        case Error(e) => e.toString()
        case ArrayValue(rows) =>
            if (rows.size == 0 || rows[0].size == 0) {
                ""
            } else {
                calcToText(rows[0][0])
            }
    }
}

/** 逻辑转换：数字非 0 为真、文本 `TRUE`/`FALSE` 可转、其余错误。 */
internal func calcToBool(value: CalcValue): ?Bool {
    match (value) {
        case Empty => Some(false)
        case Boolean(v) => Some(v)
        case Number(v) => Some(v != 0.0)
        case Text(text) =>
            match (text.toAsciiUpper()) {
                case "TRUE" => Some(true)
                case "FALSE" => Some(false)
                case _ => None<Bool>
            }
        case Error(_) => None<Bool>
        case ArrayValue(rows) =>
            if (rows.size == 1 && rows[0].size == 1) {
                calcToBool(rows[0][0])
            } else {
                None<Bool>
            }
    }
}

/**
 * 区域展平（聚合函数用）：只取标量，忽略空单元格。
 *
 * 与 Excel 一致：区域里的文本和布尔**默认被 SUM/AVERAGE 忽略**，
 * 但 `COUNTA` 等需要计数，所以这里保留全部非空值，由调用方决定。
 */
internal func flattenValues(value: CalcValue): ArrayList<CalcValue> {
    let result = ArrayList<CalcValue>()
    match (value) {
        case ArrayValue(rows) =>
            for (row in rows) {
                for (item in row) {
                    match (item) {
                        case Empty => ()
                        case ArrayValue(_) =>
                            for (inner in flattenValues(item)) {
                                result.add(inner)
                            }
                        case _ => result.add(item)
                    }
                }
            }
        case Empty => ()
        case _ => result.add(value)
    }
    result
}

/** `CellValue` → `CalcValue`；日期转序列号。 */
internal func cellValueToCalc(value: CellValue, date1904: Bool): CalcValue {
    match (value) {
        case Empty => CalcValue.Empty
        case Number(v) => CalcValue.Number(v)
        case Text(v) => CalcValue.Text(v)
        case Boolean(v) => CalcValue.Boolean(v)
        case Error(text) => match (CalcError.parse(text)) {
            case Some(e) => CalcValue.Error(e)
            case None => CalcValue.Error(CalcError.Value)
        }
        case Date(v) => CalcValue.Number(serialFromDateTime(v, date1904))
        case Formula(_, cached) => match (cached) {
            case Some(v) => cellValueToCalc(v, date1904)
            case None => CalcValue.Empty
        }
    }
}

/** `CalcValue` → `CellValue`（`recalculate(writeBack: true)` 用）。 */
internal func calcToCellValue(value: CalcValue): CellValue {
    match (value) {
        case Empty => CellValue.Empty
        case Number(v) => CellValue.Number(v)
        case Text(v) => CellValue.Text(v)
        case Boolean(v) => CellValue.Boolean(v)
        case Error(e) => CellValue.Error(e.toString())
        case ArrayValue(rows) =>
            if (rows.size == 0 || rows[0].size == 0) {
                CellValue.Empty
            } else {
                calcToCellValue(rows[0][0])
            }
    }
}

/** 序列号 → `DateTime`；调用方保证参数可转。 */
internal func serialToDateTime(serial: Float64, date1904: Bool): ?DateTime {
    dateTimeFromSerial(serial, date1904)
}

/** 三值比较：返回 -1 / 0 / 1；`None` 表示类型不可比（错误值或数组）。 */
internal func compareCalc(a: CalcValue, b: CalcValue): ?Int64 {
    let left = scalarize(a)
    let right = scalarize(b)
    match ((left, right)) {
        case (Error(_), _) => None<Int64>
        case (_, Error(_)) => None<Int64>
        case (Empty, Empty) => Some(0)
        case (Empty, Number(v)) => Some(if (0.0 < v) { -1 } else if (0.0 > v) { 1 } else { 0 })
        case (Number(v), Empty) => Some(if (v < 0.0) { -1 } else if (v > 0.0) { 1 } else { 0 })
        case (Empty, Text(t)) => Some(if (t.isEmpty()) { 0 } else { -1 })
        case (Text(t), Empty) => Some(if (t.isEmpty()) { 0 } else { 1 })
        case (Empty, Boolean(v)) => Some(if (v) { -1 } else { 0 })
        case (Boolean(v), Empty) => Some(if (v) { 1 } else { 0 })
        case (Number(x), Number(y)) => Some(if (x < y) { -1 } else if (x > y) { 1 } else { 0 })
        case (Text(x), Text(y)) =>
            let lx = x.toAsciiLower()
            let ly = y.toAsciiLower()
            Some(if (lx < ly) { -1 } else if (lx > ly) { 1 } else { 0 })
        case (Boolean(x), Boolean(y)) =>
            Some(if (x == y) { 0 } else if (!x) { -1 } else { 1 })
        case (Number(_), Text(_)) => Some(-1)
        case (Text(_), Number(_)) => Some(1)
        case (Number(_), Boolean(_)) => Some(-1)
        case (Boolean(_), Number(_)) => Some(1)
        case (Text(_), Boolean(_)) => Some(-1)
        case (Boolean(_), Text(_)) => Some(1)
        case _ => None<Int64>
    }
}

/** 单元素数组取标量；多元素数组保持原样（交给调用方报 `#VALUE!`）。 */
internal func scalarize(value: CalcValue): CalcValue {
    match (value) {
        case ArrayValue(rows) =>
            if (rows.size == 1 && rows[0].size == 1) {
                rows[0][0]
            } else {
                value
            }
        case _ => value
    }
}

/** 错误优先传播：取参数顺序中第一个错误（设计 7.4.2）。 */
internal func firstError(values: Array<CalcValue>): ?CalcError {
    for (value in values) {
        match (value) {
            case Error(e) => return Some(e)
            case ArrayValue(rows) =>
                for (row in rows) {
                    for (item in row) {
                        match (item) {
                            case Error(e) => return Some(e)
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
    }
    None<CalcError>
}
