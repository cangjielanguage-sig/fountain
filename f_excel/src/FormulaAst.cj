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

internal enum BinaryOp <: Equatable<BinaryOp> & ToString {
    | Add
    | Sub
    | Mul
    | Div
    | Pow
    | Concat
    | Eq
    | Ne
    | Lt
    | Gt
    | Le
    | Ge

    public operator func ==(that: BinaryOp): Bool {
        this.toString() == that.toString()
    }

    public operator func !=(that: BinaryOp): Bool {
        !(this == that)
    }

    public func toString(): String {
        match (this) {
            case Add => "+"
            case Sub => "-"
            case Mul => "*"
            case Div => "/"
            case Pow => "^"
            case Concat => "&"
            case Eq => "="
            case Ne => "<>"
            case Lt => "<"
            case Gt => ">"
            case Le => "<="
            case Ge => ">="
        }
    }
}

internal enum UnaryOp <: Equatable<UnaryOp> {
    | Neg
    | Pos

    public operator func ==(that: UnaryOp): Bool {
        match ((this, that)) {
            case (Neg, Neg) => true
            case (Pos, Pos) => true
            case _ => false
        }
    }

    public operator func !=(that: UnaryOp): Bool {
        !(this == that)
    }
}

/**
 * 公式 AST（设计 7.3）。
 *
 * `Ref` / `RangeExpr` 的 `?String` 是工作表名；`None` 表示"公式所在的工作表"，
 * 解析阶段不做跨表检查——表名是否存在由求值阶段报 `#REF!`。
 */
internal enum Expr <: ToString {
    | Lit(CalcValue)
    | Ref(?String, CellRef)
    | RangeExpr(?String, CellRef, CellRef)
    | Unary(UnaryOp, Expr)
    | Binary(BinaryOp, Expr, Expr)
    | Call(String, Array<Expr>)
    | ArrayLit(Array<Array<Expr>>)

    public func toString(): String {
        match (this) {
            case Lit(v) => v.toString()
            case Ref(sheet, cell) => match (sheet) {
                case Some(name) => "'${name}'!${cell.toA1()}"
                case None => cell.toA1()
            }
            case RangeExpr(sheet, from, to) => match (sheet) {
                case Some(name) => "'${name}'!${from.toA1()}:${to.toA1()}"
                case None => "${from.toA1()}:${to.toA1()}"
            }
            case Unary(op, inner) => match (op) {
                case Neg => "-${inner}"
                case Pos => "+${inner}"
            }
            case Binary(op, left, right) => "(${left}${op}${right})"
            case Call(name, args) =>
                let parts = ArrayList<String>()
                for (arg in args) {
                    parts.add(arg.toString())
                }
                let joined = joinText(parts, ",")
                "${name}(${joined})"
            case ArrayLit(rows) =>
                let out = ArrayList<String>()
                for (row in rows) {
                    let cells = ArrayList<String>()
                    for (item in row) {
                        cells.add(item.toString())
                    }
                    out.add(joinText(cells, ","))
                }
                let joined = joinText(out, ";")
                "{${joined}}"
        }
    }
}

/**
 * 收集表达式里引用到的单元格（依赖图用）。
 *
 * 区域只记录**边界**：`A1:B3` 记 6 个格子，代价与区域大小成正比；
 * 依赖图对这种"大区域"用行/列区间表示不划算，M2 直接展开并设上限
 * （超过 [MAX_DEPENDENCY_CELLS] 时只记左上与右下，重算走保守路径）。
 */
internal let MAX_DEPENDENCY_CELLS: Int64 = 65_536

internal func joinText(parts: ArrayList<String>, separator: String): String {
    var out = ""
    var first = true
    for (part in parts) {
        if (!first) {
            out += separator
        }
        out += part
        first = false
    }
    out
}

internal func collectRefs(expr: Expr, defaultSheet: String, out: ArrayList<(String, Int64, Int64)>): Unit {
    match (expr) {
        case Lit(_) => ()
        case Ref(sheet, cell) =>
            let name = match (sheet) {
                case Some(v) => v
                case None => defaultSheet
            }
            out.add((name, cell.row, cell.col))
        case RangeExpr(sheet, from, to) =>
            let name = match (sheet) {
                case Some(v) => v
                case None => defaultSheet
            }
            let area = (to.row - from.row + 1) * (to.col - from.col + 1)
            if (area <= MAX_DEPENDENCY_CELLS) {
                for (row in from.row..=to.row) {
                    for (col in from.col..=to.col) {
                        out.add((name, row, col))
                    }
                }
            } else {
                out.add((name, from.row, from.col))
                out.add((name, to.row, to.col))
            }
        case Unary(_, inner) => collectRefs(inner, defaultSheet, out)
        case Binary(_, left, right) =>
            collectRefs(left, defaultSheet, out)
            collectRefs(right, defaultSheet, out)
        case Call(_, args) =>
            for (arg in args) {
                collectRefs(arg, defaultSheet, out)
            }
        case ArrayLit(rows) =>
            for (row in rows) {
                for (item in row) {
                    collectRefs(item, defaultSheet, out)
                }
            }
    }
}
