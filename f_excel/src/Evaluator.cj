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

/** 求值环境：由 [CalcEngine] 实现，负责取单元格值与表边界。 */
internal interface CalcResolver {
    func valueAt(sheet: String, row: Int64, col: Int64): CalcValue

    func sheetExists(name: String): Bool

    /** 已用区域右下角；整列引用会按它裁剪，避免遍历 100 万行。 */
    func usedBounds(sheet: String): (Int64, Int64)

    func date1904(): Bool
}

/**
 * 表达式求值器（设计 7.4 / 7.6）。
 *
 * 一次求值（一个 `evaluate` 或一个 `recalculate`）共用一个实例，所以
 * `NOW()` / `TODAY()` / `RAND()` 在这次求值内保持一致——这是设计 7.5.2 的要求。
 */
internal class Evaluator {
    public let resolver: CalcResolver
    public let now: DateTime
    private var randomState: Int64

    public init(resolver: CalcResolver, now!: DateTime = DateTime.now()) {
        this.resolver = resolver
        this.now = now
        this.randomState = now.toUnixTimeStamp().toNanoseconds() & 0x7FFF_FFFF
    }

    public func eval(expr: Expr): CalcValue {
        match (expr) {
            case Lit(value) => value
            case Ref(sheet, cell) =>
                let name = match (sheet) {
                    case Some(v) => v
                    case None => ""
                }
                this.resolver.valueAt(name, cell.row, cell.col)
            case RangeExpr(sheet, from, to) => this.rangeValue(sheet, from, to)
            case Unary(op, inner) => this.evalUnary(op, this.eval(inner))
            case Binary(op, left, right) => this.evalBinary(op, this.eval(left), this.eval(right))
            case Call(name, args) => match (lookupFunction(name)) {
                case Some(entry) =>
                    if (args.size < entry.minArgs || (entry.maxArgs >= 0 && args.size > entry.maxArgs)) {
                        CalcValue.Error(CalcError.Value)
                    } else {
                        entry.impl(this, args)
                    }
                case None => CalcValue.Error(CalcError.Name)
            }
            case ArrayLit(rows) =>
                let values = ArrayList<Array<CalcValue>>()
                for (row in rows) {
                    let items = ArrayList<CalcValue>()
                    for (item in row) {
                        items.add(scalarize(this.eval(item)))
                    }
                    values.add(items.toArray())
                }
                CalcValue.ArrayValue(values.toArray())
        }
    }

    /** 区域取值：按已用区域裁剪，整列/整行引用不会撑爆内存。 */
    public func rangeValue(sheet: ?String, from: CellRef, to: CellRef): CalcValue {
        let name = match (sheet) {
            case Some(v) => v
            case None => ""
        }
        if (!this.resolver.sheetExists(name) && sheet.isSome()) {
            return CalcValue.Error(CalcError.Ref)
        }
        let (maxRow, maxCol) = this.resolver.usedBounds(name)
        let lastRow = if (to.row > maxRow) { maxRow } else { to.row }
        let lastCol = if (to.col > maxCol) { maxCol } else { to.col }
        let rows = ArrayList<Array<CalcValue>>()
        var row = from.row
        while (row <= lastRow) {
            let items = ArrayList<CalcValue>()
            var col = from.col
            while (col <= lastCol) {
                items.add(this.resolver.valueAt(name, row, col))
                col++
            }
            rows.add(items.toArray())
            row++
        }
        if (rows.size == 0) {
            return CalcValue.ArrayValue(Array<Array<CalcValue>>())
        }
        CalcValue.ArrayValue(rows.toArray())
    }

    /** 求值某个实参。 */
    public func arg(args: Array<Expr>, index: Int64): CalcValue {
        if (index < 0 || index >= args.size) {
            return CalcValue.Empty
        }
        this.eval(args[index])
    }

    /** `[0,1)` 伪随机数；同一次求值内可重复（设计 7.5.2）。 */
    public func nextRandom(): Float64 {
        this.randomState = (this.randomState * 1_103_515_245 + 12_345) & 0x7FFF_FFFF_FFFF_FFFF
        Float64(this.randomState % 100_000_000) / 100_000_000.0
    }

    public func todaySerial(): Float64 {
        let base = if (this.resolver.date1904()) {
            utcDayNumber(1904, 1, 1)
        } else {
            utcDayNumber(1899, 12, 30)
        }
        let days = this.now.toUnixTimeStamp().toNanoseconds() / 86_400_000_000_000
        Float64(days - base)
    }

    public func nowSerial(): Float64 {
        let nanos = this.now.toUnixTimeStamp().toNanoseconds()
        let secondsOfDay = (nanos % 86_400_000_000_000) / 1_000_000_000
        this.todaySerial() + Float64(secondsOfDay) / 86400.0
    }

    private func evalUnary(op: UnaryOp, value: CalcValue): CalcValue {
        match (firstError([value])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        let number = match (calcToNumber(scalarize(value))) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
        match (op) {
            case Neg => CalcValue.Number(-number)
            case Pos => CalcValue.Number(number)
        }
    }

    private func evalBinary(op: BinaryOp, leftValue: CalcValue, rightValue: CalcValue): CalcValue {
        match (firstError([leftValue, rightValue])) {
            case Some(e) => return CalcValue.Error(e)
            case None => ()
        }
        let left = scalarize(leftValue)
        let right = scalarize(rightValue)
        if (op == BinaryOp.Concat) {
            return CalcValue.Text(calcToText(left) + calcToText(right))
        }
        let isComparison = op == BinaryOp.Eq || op == BinaryOp.Ne || op == BinaryOp.Lt ||
            op == BinaryOp.Gt || op == BinaryOp.Le || op == BinaryOp.Ge
        if (isComparison) {
            let order = match (compareCalc(left, right)) {
                case Some(v) => v
                case None => return CalcValue.Error(CalcError.Value)
            }
            let result = match (op) {
                case Eq => order == 0
                case Ne => order != 0
                case Lt => order < 0
                case Gt => order > 0
                case Le => order <= 0
                case _ => order >= 0
            }
            return CalcValue.Boolean(result)
        }
        let a = match (calcToNumber(left)) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
        let b = match (calcToNumber(right)) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Value)
        }
        match (op) {
            case Add => CalcValue.Number(a + b)
            case Sub => CalcValue.Number(a - b)
            case Mul => CalcValue.Number(a * b)
            case Div => if (b == 0.0) {
                CalcValue.Error(CalcError.DivZero)
            } else {
                CalcValue.Number(a / b)
            }
            case Pow =>
                let result = pow(a, b)
                if (result.isNaN() || result.isInf()) {
                    CalcValue.Error(CalcError.Num)
                } else {
                    CalcValue.Number(result)
                }
            case _ => CalcValue.Error(CalcError.Value)
        }
    }
}
