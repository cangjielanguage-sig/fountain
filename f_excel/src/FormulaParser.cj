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

/**
 * 公式语法分析（设计 7.3 的优先级表）。
 *
 * 三处必须按 Excel 而不是数学惯例：
 * 1. 一元负号比 `^` 高：`-2^2 = 4`；
 * 2. `^` 左结合：`2^3^2 = 64`；
 * 3. `%` 是后缀运算符：`50% = 0.5`。
 */
internal class FormulaParser {
    private let tokens: Array<FToken>
    private var pos: Int64 = 0

    private init(tokens: Array<FToken>) {
        this.tokens = tokens
    }

    /** 解析公式原文（可带前导 `=`）；语法错误返回 `None`。 */
    public static func parse(source: String): ?Expr {
        var text = source.trimAscii()
        if (text.startsWith("=")) {
            text = text[1..].trimAscii()
        }
        if (text.isEmpty()) {
            return None<Expr>
        }
        try {
            let parser = FormulaParser(tokenizeFormula(text))
            let expr = parser.parseExpression()
            if (parser.peek().kind != FTokKind.End) {
                return None<Expr>
            }
            Some(expr)
        } catch (_: FormulaSyntaxException) {
            None<Expr>
        } catch (_: Exception) {
            None<Expr>
        }
    }

    private func peek(): FToken {
        this.tokens[this.pos]
    }

    private func advance(): FToken {
        let token = this.tokens[this.pos]
        if (this.pos < this.tokens.size - 1) {
            this.pos++
        }
        token
    }

    private func expect(kind: FTokKind, what: String): FToken {
        let token = this.peek()
        if (token.kind != kind) {
            throw FormulaSyntaxException("期望 ${what}，实际 ${token}")
        }
        this.advance()
    }

    private func parseExpression(): Expr {
        this.parseComparison()
    }

    private func parseComparison(): Expr {
        var left = this.parseConcat()
        while (this.peek().kind == FTokKind.Op) {
            let text = this.peek().text
            let isComparison = text == "=" || text == "<>" || text == "<" || text == ">" ||
                text == "<=" || text == ">="
            if (!isComparison) {
                break
            }
            this.advance()
            let op = match (text) {
                case "=" => BinaryOp.Eq
                case "<>" => BinaryOp.Ne
                case "<" => BinaryOp.Lt
                case ">" => BinaryOp.Gt
                case "<=" => BinaryOp.Le
                case _ => BinaryOp.Ge
            }
            left = Expr.Binary(op, left, this.parseConcat())
        }
        left
    }

    private func parseConcat(): Expr {
        var left = this.parseAdditive()
        while (this.peek().kind == FTokKind.Op && this.peek().text == "&") {
            this.advance()
            left = Expr.Binary(BinaryOp.Concat, left, this.parseAdditive())
        }
        left
    }

    private func parseAdditive(): Expr {
        var left = this.parseMultiplicative()
        while (this.peek().kind == FTokKind.Op) {
            let text = this.peek().text
            if (text != "+" && text != "-") {
                break
            }
            this.advance()
            let op = if (text == "+") { BinaryOp.Add } else { BinaryOp.Sub }
            left = Expr.Binary(op, left, this.parseMultiplicative())
        }
        left
    }

    private func parseMultiplicative(): Expr {
        var left = this.parsePower()
        while (this.peek().kind == FTokKind.Op) {
            let text = this.peek().text
            if (text != "*" && text != "/") {
                break
            }
            this.advance()
            let op = if (text == "*") { BinaryOp.Mul } else { BinaryOp.Div }
            left = Expr.Binary(op, left, this.parsePower())
        }
        left
    }

    /** `^` 左结合，且右侧允许一元负号（`2^-1`）。 */
    private func parsePower(): Expr {
        var left = this.parseUnary()
        while (this.peek().kind == FTokKind.Op && this.peek().text == "^") {
            this.advance()
            left = Expr.Binary(BinaryOp.Pow, left, this.parseUnary())
        }
        left
    }

    private func parseUnary(): Expr {
        let token = this.peek()
        if (token.kind == FTokKind.Op && (token.text == "-" || token.text == "+")) {
            this.advance()
            let inner = this.parseUnary()
            return Expr.Unary(if (token.text == "-") { UnaryOp.Neg } else { UnaryOp.Pos }, inner)
        }
        this.parsePercent()
    }

    private func parsePercent(): Expr {
        var value = this.parsePrimary()
        while (this.peek().kind == FTokKind.Percent) {
            this.advance()
            value = Expr.Binary(BinaryOp.Div, value, Expr.Lit(CalcValue.Number(100.0)))
        }
        value
    }

    private func parsePrimary(): Expr {
        let token = this.peek()
        match (token.kind) {
            case FTokKind.Num =>
                this.advance()
                // 整行引用 `1:1`：数字后面直接跟冒号
                if (this.peek().kind == FTokKind.Colon) {
                    let first = Int64(token.number)
                    this.advance()
                    let secondToken = this.expect(FTokKind.Num, "行号")
                    let second = Int64(secondToken.number)
                    if (first < 1 || second < 1 || first > EXCEL_MAX_ROW || second > EXCEL_MAX_ROW ||
                        first > second) {
                        throw FormulaSyntaxException("非法的整行引用")
                    }
                    return Expr.RangeExpr(
                        None,
                        CellRef(first, 1),
                        CellRef(second, EXCEL_MAX_COL)
                    )
                }
                Expr.Lit(CalcValue.Number(token.number))
            case FTokKind.Str =>
                this.advance()
                Expr.Lit(CalcValue.Text(token.text))
            case FTokKind.Ident =>
                this.advance()
                this.parseIdent(token.text)
            case FTokKind.Quoted =>
                this.advance()
                let sheet = token.text
                this.expect(FTokKind.Bang, "!（工作表分隔符）")
                let refToken = this.expect(FTokKind.Ident, "单元格引用")
                this.parseRef(refToken.text, Some(sheet))
            case FTokKind.LParen =>
                this.advance()
                let inner = this.parseExpression()
                this.expect(FTokKind.RParen, ")")
                inner
            case FTokKind.LBrace =>
                this.parseArrayLiteral()
            case _ => throw FormulaSyntaxException("无法解析的记号：${token}")
        }
    }

    private func parseIdent(text: String): Expr {
        let upper = text.toAsciiUpper()
        if (upper == "TRUE") {
            return Expr.Lit(CalcValue.Boolean(true))
        }
        if (upper == "FALSE") {
            return Expr.Lit(CalcValue.Boolean(false))
        }
        if (text.startsWith("#")) {
            return match (CalcError.parse(text)) {
                case Some(e) => Expr.Lit(CalcValue.Error(e))
                case None => throw FormulaSyntaxException("未知错误值：${text}")
            }
        }
        if (this.peek().kind == FTokKind.LParen) {
            return this.parseCall(upper)
        }
        if (this.peek().kind == FTokKind.Bang) {
            this.advance()
            let refToken = this.expect(FTokKind.Ident, "单元格引用")
            return this.parseRef(refToken.text, Some(text))
        }
        this.parseRef(text, None)
    }

    private func parseCall(name: String): Expr {
        this.expect(FTokKind.LParen, "(")
        let args = ArrayList<Expr>()
        if (this.peek().kind != FTokKind.RParen) {
            while (true) {
                if (this.peek().kind == FTokKind.Comma || this.peek().kind == FTokKind.RParen) {
                    // 允许空实参（`IF(A1,,1)`），按空字面量处理
                    args.add(Expr.Lit(CalcValue.Empty))
                } else {
                    args.add(this.parseExpression())
                }
                if (this.peek().kind == FTokKind.Comma) {
                    this.advance()
                    continue
                }
                break
            }
        }
        this.expect(FTokKind.RParen, ")")
        Expr.Call(name, args.toArray())
    }

    private func parseArrayLiteral(): Expr {
        this.expect(FTokKind.LBrace, "{")
        let rows = ArrayList<Array<Expr>>()
        var row = ArrayList<Expr>()
        while (true) {
            row.add(this.parseExpression())
            if (this.peek().kind == FTokKind.Comma) {
                this.advance()
                continue
            }
            rows.add(row.toArray())
            if (this.peek().kind == FTokKind.Semicolon) {
                this.advance()
                row = ArrayList<Expr>()
                continue
            }
            break
        }
        this.expect(FTokKind.RBrace, "}")
        Expr.ArrayLit(rows.toArray())
    }

    /** 引用或区域；支持整列 `A:A` / `$A:$C` 与整行 `1:1`。 */
    private func parseRef(text: String, sheet: ?String): Expr {
        let first = parseRefPart(text)
        if (this.peek().kind != FTokKind.Colon) {
            return match (first) {
                case RefPart.Cell(value) => Expr.Ref(sheet, value)
                case RefPart.Column(value) => Expr.RangeExpr(
                    sheet,
                    CellRef(1, value.col, colAbs: value.colAbs),
                    CellRef(EXCEL_MAX_ROW, value.col, colAbs: value.colAbs)
                )
                case RefPart.Row(value) => Expr.RangeExpr(
                    sheet,
                    CellRef(value.row, 1, rowAbs: value.rowAbs),
                    CellRef(value.row, EXCEL_MAX_COL, rowAbs: value.rowAbs)
                )
            }
        }
        this.advance()
        let secondToken = this.expect(FTokKind.Ident, "区域右端")
        let second = parseRefPart(secondToken.text)
        match ((first, second)) {
            case (RefPart.Cell(from), RefPart.Cell(to)) =>
                if (from.row > to.row || from.col > to.col) {
                    throw FormulaSyntaxException("区域倒置：${from.toA1()}:${to.toA1()}")
                }
                Expr.RangeExpr(sheet, from, to)
            case (RefPart.Column(from), RefPart.Column(to)) =>
                if (from.col > to.col) {
                    throw FormulaSyntaxException("列区域倒置")
                }
                Expr.RangeExpr(
                    sheet,
                    CellRef(1, from.col, colAbs: from.colAbs),
                    CellRef(EXCEL_MAX_ROW, to.col, colAbs: to.colAbs)
                )
            case (RefPart.Row(from), RefPart.Row(to)) =>
                if (from.row > to.row) {
                    throw FormulaSyntaxException("行区域倒置")
                }
                Expr.RangeExpr(
                    sheet,
                    CellRef(from.row, 1, rowAbs: from.rowAbs),
                    CellRef(to.row, EXCEL_MAX_COL, rowAbs: to.rowAbs)
                )
            case _ => throw FormulaSyntaxException("区域两端类型不一致")
        }
    }
}

internal enum RefPart {
    | Cell(CellRef)
    | Column(CellRef)
    | Row(CellRef)
}

private func parseRefPart(text: String): RefPart {
    match (CellRef.parse(text)) {
        case Some(value) => return RefPart.Cell(value)
        case None => ()
    }
    // 整列：可选 $ + 字母
    var body = text
    var colAbs = false
    if (body.startsWith("$")) {
        colAbs = true
        body = body[1..]
    }
    if (!body.isEmpty()) {
        let col = columnIndex(body)
        if (col.isSome()) {
            return RefPart.Column(CellRef(1, col.getOrThrow(), colAbs: colAbs))
        }
    }
    // 整行：可选 $ + 数字
    var rowBody = text
    var rowAbs = false
    if (rowBody.startsWith("$")) {
        rowAbs = true
        rowBody = rowBody[1..]
    }
    if (!rowBody.isEmpty()) {
        let row = try {
            Int64.parse(rowBody)
        } catch (_: Exception) {
            -1
        }
        if (row >= 1 && row <= EXCEL_MAX_ROW) {
            return RefPart.Row(CellRef(row, 1, rowAbs: rowAbs))
        }
    }
    throw FormulaSyntaxException("无法解析引用：${text}")
}
