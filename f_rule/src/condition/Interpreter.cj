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
package fountain::f_rule.condition

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.time.DateTime
import fountain::f_rule.exception.*
import fountain::f_rule.fact.Fact

/**
 * 受限表达式 AST（`doc/03-condition-expression.md` §7）。
 *
 * 只覆盖动态事实与决策表需要的子集：字段访问、字面量、比较、`&& || !`、白名单函数。
 * 没有算术与赋值——这些交给 JIT 路径。
 */
enum InterpreterExpr {
    | Literal(Any)
    | NullLiteral
    | FieldRef(Array<String>)
    | FuncCall(String, Array<InterpreterExpr>)
    | NotExpr(InterpreterExpr)
    | AndExpr(InterpreterExpr, InterpreterExpr)
    | OrExpr(InterpreterExpr, InterpreterExpr)
    | CompareExpr(Operator, InterpreterExpr, InterpreterExpr)
}

/**
 * 内置解释器（`doc/03-condition-expression.md` §7）。
 *
 * 语法：`|| < && < ! < 比较`，`primary` 支持括号、字段、字面量与白名单函数。
 * 任何求值异常都视为 `Unknown`（不产生激活）；节点步数上限防止病态表达式拖死议程。
 */
public class InterpreterProgram {
    private let root: InterpreterExpr
    private let maxSteps: Int64
    private var steps: Int64
    private var deadline: ?DateTime

    private init(root: InterpreterExpr, maxSteps: Int64) {
        this.root = root
        this.maxSteps = maxSteps
        this.steps = 0
        this.deadline = None
    }

    /** 供 `JitExpression` 使用的公开入口；语法/函数错误抛 `SCRIPT_COMPILE`。 */
    public static func compile(source: String, maxSteps!: Int64 = 1_000_000): InterpreterProgram {
        InterpreterProgram(ExpressionParser.parse(source, maxSteps), maxSteps)
    }

    /** 求值；异常与超限一律 `Unknown`，不穿透到事件循环。 */
    public func eval(bindings: HashMap<String, Fact>): Truth {
        evaluate(bindings, None)[0]
    }

    /**
     * 求值并保留失败分类；超时按 `ExpressionTimeoutException` 识别。
     *
     * @param deadline 单次求值截止时间；`None` 表示不设墙钟上限
     */
    public func evalOutcome(bindings: HashMap<String, Fact>,
        deadline!: ?DateTime = None): EvalOutcome {
        let result = evaluate(bindings, deadline)
        match (result[1]) {
            case EvalFailureKind.Evaluated => EvalOutcome.evaluated(result[0].isTrue())
            case kind => EvalOutcome.failed(kind, result[2])
        }
    }

    private func evaluate(bindings: HashMap<String, Fact>,
        limit: ?DateTime): (Truth, EvalFailureKind, String) {
        steps = 0
        deadline = limit
        try {
            (truthOf(root, bindings), EvalFailureKind.Evaluated, "")
        } catch (e: ExpressionTimeoutException) {
            (Truth.Unknown, EvalFailureKind.Timeout, e.message)
        } catch (e: RuleException) {
            if (e.code == RuleErrorCode.TYPE_MISMATCH) {
                (Truth.Unknown, EvalFailureKind.TypeMismatch, e.message)
            } else {
                (Truth.Unknown, EvalFailureKind.RuntimeFailure, e.message)
            }
        } catch (e: Exception) {
            (Truth.Unknown, EvalFailureKind.RuntimeFailure, e.message)
        }
    }

    private func tick(): Unit {
        steps += 1
        if (steps > maxSteps) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "表达式求值步数超过上限 ${maxSteps}"
            )
        }
        match (deadline) {
            case Some(limit) =>
                if (DateTime.now() >= limit) {
                    throw ExpressionTimeoutException()
                }
            case None => ()
        }
    }

    private func truthOf(expr: InterpreterExpr, bindings: HashMap<String, Fact>): Truth {
        tick()
        match (expr) {
            case AndExpr(left, right) =>
                let first = truthOf(left, bindings)
                match (first) {
                    case Truth.False => Truth.False
                    case _ => first.and(truthOf(right, bindings))
                }
            case OrExpr(left, right) =>
                let first = truthOf(left, bindings)
                match (first) {
                    case Truth.True => Truth.True
                    case _ => first.or(truthOf(right, bindings))
                }
            case NotExpr(inner) => truthOf(inner, bindings).not()
            case CompareExpr(op, left, right) =>
                let leftValue = valueOf(left, bindings)
                let rightValue = valueOf(right, bindings)
                OperatorEvaluator.apply(op, leftValue, rightValue)
            case Literal(value) =>
                match (value) {
                    case flag: Bool => if (flag) { Truth.True } else { Truth.False }
                    case _ => Truth.Unknown
                }
            case NullLiteral => Truth.Unknown
            case FieldRef(segments) =>
                match (resolveField(segments, bindings)) {
                    case Some(value) =>
                        match (value) {
                            case flag: Bool => if (flag) { Truth.True } else { Truth.False }
                            case _ => Truth.Unknown
                        }
                    case None => Truth.Unknown
                }
            case FuncCall(name, args) =>
                match (invoke(name, args, bindings)) {
                    case Some(value) =>
                        match (value) {
                            case flag: Bool => if (flag) { Truth.True } else { Truth.False }
                            case _ => Truth.Unknown
                        }
                    case None => Truth.Unknown
                }
        }
    }

    private func valueOf(expr: InterpreterExpr, bindings: HashMap<String, Fact>): ?Any {
        tick()
        match (expr) {
            case Literal(value) => Some(value)
            case NullLiteral => None
            case FieldRef(segments) => resolveField(segments, bindings)
            case FuncCall(name, args) => invoke(name, args, bindings)
            case NotExpr(_) | AndExpr(_, _) | OrExpr(_, _) | CompareExpr(_, _, _) =>
                let truth = truthOf(expr, bindings)
                match (truth) {
                    case Truth.True => Some(true)
                    case Truth.False => Some(false)
                    case Truth.Unknown => None
                }
        }
    }

    /**
     * 字段解析。
     *
     * - `o.amount`：按绑定名 `o` 取事实再取值；
     * - `amount`：只有一个绑定时的简写（决策表 `expr` 列与动态事实常用）；
     * - 绑定缺失或字段缺失：`None`（外层判为 `Unknown`）。
     */
    private func resolveField(segments: Array<String>, bindings: HashMap<String, Fact>): ?Any {
        if (segments.size == 0) {
            return None
        }
        let first = segments[0]
        match (bindings.get(first)) {
            case Some(fact) =>
                if (segments.size == 1) {
                    return Some(fact)
                }
                return fact.get(segments[1])
            case None => ()
        }
        if (segments.size == 1 && bindings.size == 1) {
            for ((_, fact) in bindings) {
                return fact.get(first)
            }
        }
        None
    }

    private func invoke(name: String, args: Array<InterpreterExpr>, bindings: HashMap<String, Fact>): ?Any {
        if (!InterpreterProgram.isWhitelisted(name)) {
            throw RuleException(RuleErrorCode.SCRIPT_COMPILE, "解释器不支持函数 ${name}")
        }
        let values = ArrayList<Any>()
        for (arg in args) {
            match (valueOf(arg, bindings)) {
                case Some(value) => values.add(value)
                case None => return None
            }
        }
        match (name) {
            case "lower" => stringResult(values, { s => s.toAsciiLower() })
            case "upper" => stringResult(values, { s => s.toAsciiUpper() })
            case "trim" => stringResult(values, { s => s.trimAscii() })
            case "length" =>
                match (values[0]) {
                    case text: String => Some(Int64(text.size))
                    case items: Array<Any> => Some(Int64(items.size))
                    case items: Collection<Any> => Some(items.size)
                    case _ => None
                }
            case "abs" =>
                match (values[0]) {
                    case n: Int64 => Some(if (n < 0) { -n } else { n })
                    case n: Float64 => Some(if (n < 0.0) { -n } else { n })
                    case _ => None
                }
            case "round" =>
                match (values[0]) {
                    case n: Float64 =>
                        Some(if (n >= 0.0) { Float64(Int64(n + 0.5)) } else { Float64(Int64(n - 0.5)) })
                    case n: Int64 => Some(n)
                    case _ => None
                }
            case "now" => Some(DateTime.now())
            case "dayOfWeek" =>
                match (values[0]) {
                    case time: DateTime => Some(Int64(time.dayOfWeek.toInteger()))
                    case _ => None
                }
            case "contains" =>
                Some(OperatorEvaluator.apply(Operator.Contains, Some(values[0]), Some(values[1])).isTrue())
            case "startsWith" =>
                Some(OperatorEvaluator.apply(Operator.StartsWith, Some(values[0]), Some(values[1])).isTrue())
            case "endsWith" =>
                Some(OperatorEvaluator.apply(Operator.EndsWith, Some(values[0]), Some(values[1])).isTrue())
            case _ => None
        }
    }

    private func stringResult(values: ArrayList<Any>, transform: (String) -> String): ?Any {
        match (values[0]) {
            case text: String => Some(transform(text))
            case _ => None
        }
    }

    /** 白名单 10 个函数（`doc/03` §7）。 */
    public static func isWhitelisted(name: String): Bool {
        match (name) {
            case "lower" | "upper" | "trim" | "length" | "abs" | "round" | "now" | "dayOfWeek" |
                "contains" | "startsWith" | "endsWith" => true
            case _ => false
        }
    }
}

/** 递归下降解析器；只认 ASCII 语法字符，字符串内容按 UTF-8 原样收集。 */
class ExpressionParser {
    private let source: String
    private let maxNodes: Int64
    private var pos: Int64
    private var nodes: Int64

    private init(source: String, maxNodes: Int64) {
        this.source = source
        this.maxNodes = maxNodes
        this.pos = 0
        this.nodes = 0
    }

    static func parse(source: String, maxNodes: Int64): InterpreterExpr {
        let parser = ExpressionParser(source, maxNodes)
        let expr = parser.parseOr()
        parser.skipSpaces()
        if (parser.pos < Int64(source.size)) {
            parser.fail("表达式末尾有多余字符")
        }
        expr
    }

    private func fail(message: String): Nothing {
        throw RuleException(
            RuleErrorCode.SCRIPT_COMPILE,
            "${message}（位置 ${pos}）"
        )
    }

    private func countNode(): Unit {
        nodes += 1
        if (nodes > maxNodes) {
            fail("表达式节点数超过上限 ${maxNodes}")
        }
    }

    private func skipSpaces(): Unit {
        while (pos < Int64(source.size)) {
            let c = source[pos]
            if (c == 32 || c == 9 || c == 10 || c == 13) {
                pos += 1
            } else {
                break
            }
        }
    }

    private func peek(): ?UInt8 {
        if (pos < Int64(source.size)) {
            Some(source[pos])
        } else {
            None
        }
    }

    private func matchText(text: String): Bool {
        skipSpaces()
        let size = Int64(text.size)
        if (pos + size > Int64(source.size)) {
            return false
        }
        var i: Int64 = 0
        while (i < size) {
            if (source[pos + i] != text[i]) {
                return false
            }
            i += 1
        }
        pos += size
        true
    }

    private func parseOr(): InterpreterExpr {
        var left = parseAnd()
        while (true) {
            let save = pos
            if (matchText("||")) {
                countNode()
                left = OrExpr(left, parseAnd())
            } else {
                pos = save
                break
            }
        }
        left
    }

    private func parseAnd(): InterpreterExpr {
        var left = parseUnary()
        while (true) {
            let save = pos
            if (matchText("&&")) {
                countNode()
                left = AndExpr(left, parseUnary())
            } else {
                pos = save
                break
            }
        }
        left
    }

    private func parseUnary(): InterpreterExpr {
        skipSpaces()
        if (matchText("!")) {
            countNode()
            return NotExpr(parseUnary())
        }
        parsePrimary()
    }

    private func parsePrimary(): InterpreterExpr {
        skipSpaces()
        if (matchText("(")) {
            let inner = parseOr()
            if (!matchText(")")) {
                fail("缺少右括号")
            }
            return inner
        }
        parseComparison()
    }

    private func parseComparison(): InterpreterExpr {
        let left = parseTerm()
        skipSpaces()
        let op = matchComparison()
        match (op) {
            case Some(found) =>
                countNode()
                CompareExpr(found, left, parseTerm())
            case None => left
        }
    }

    private func matchComparison(): ?Operator {
        for ((text, op) in [
            ("==", Operator.Eq), ("!=", Operator.Ne),
            (">=", Operator.Ge), ("<=", Operator.Le),
            (">", Operator.Gt), ("<", Operator.Lt)
        ]) {
            let save = pos
            if (matchText(text)) {
                return Some(op)
            }
            pos = save
        }
        None
    }

    private func parseTerm(): InterpreterExpr {
        skipSpaces()
        countNode()
        match (peek()) {
            case Some(c) =>
                if (c == 34 || c == 39) {
                    return Literal(parseString(c))
                }
                if (c == 45 || (c >= 48 && c <= 57)) {
                    return parseNumber()
                }
            case None => ()
        }
        parseIdentifier()
    }

    private func parseNumber(): InterpreterExpr {
        skipSpaces()
        var negative = false
        if (matchText("-")) {
            negative = true
        }
        let start = pos
        var isFloat = false
        while (pos < Int64(source.size)) {
            let c = source[pos]
            if (c >= 48 && c <= 57) {
                pos += 1
            } else if (c == 46) {
                isFloat = true
                pos += 1
            } else {
                break
            }
        }
        if (pos == start) {
            fail("数字字面量非法")
        }
        let text = source[start..pos]
        if (isFloat) {
            let value = Float64.parse(text)
            Literal(if (negative) { -value } else { value })
        } else {
            let value = Int64.parse(text)
            Literal(if (negative) { -value } else { value })
        }
    }

    private func parseString(quoteChar: UInt8): String {
        pos += 1
        let bytes = ArrayList<UInt8>()
        while (pos < Int64(source.size)) {
            let c = source[pos]
            pos += 1
            if (c == quoteChar) {
                return String.fromUtf8(bytes.toArray())
            }
            if (c == 92) {
                if (pos >= Int64(source.size)) {
                    fail("字符串转义不完整")
                }
                let escaped = source[pos]
                pos += 1
                match (escaped) {
                    case 110 => bytes.add(10)   // \n
                    case 116 => bytes.add(9)    // \t
                    case 114 => bytes.add(13)   // \r
                    case 92 => bytes.add(92)    // \\
                    case 34 => bytes.add(34)    // \"
                    case 39 => bytes.add(39)    // \'
                    case _ => bytes.add(escaped)
                }
            } else {
                bytes.add(c)
            }
        }
        fail("字符串未闭合")
    }

    private func parseIdentifier(): InterpreterExpr {
        skipSpaces()
        let start = pos
        while (pos < Int64(source.size)) {
            let c = source[pos]
            let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
            if (ok) {
                pos += 1
            } else {
                break
            }
        }
        if (pos == start) {
            fail("缺少标识符或字面量")
        }
        let name = source[start..pos]
        match (name) {
            case "true" => return Literal(true)
            case "false" => return Literal(false)
            case "null" => return NullLiteral
            case _ => ()
        }
        skipSpaces()
        if (pos < Int64(source.size) && source[pos] == 40) {   // '('
            return parseCall(name)
        }
        let segments = ArrayList<String>()
        segments.add(name)
        while (true) {
            let save = pos
            if (matchText(".")) {
                skipSpaces()
                let segmentStart = pos
                while (pos < Int64(source.size)) {
                    let c = source[pos]
                    let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
                    if (ok) {
                        pos += 1
                    } else {
                        break
                    }
                }
                if (pos == segmentStart) {
                    fail("字段名为空")
                }
                segments.add(source[segmentStart..pos])
            } else {
                pos = save
                break
            }
        }
        FieldRef(segments.toArray())
    }

    private func parseCall(name: String): InterpreterExpr {
        if (!InterpreterProgram.isWhitelisted(name)) {
            fail("解释器不支持函数 ${name}")
        }
        if (!matchText("(")) {
            fail("缺少左括号")
        }
        let args = ArrayList<InterpreterExpr>()
        skipSpaces()
        let save = pos
        if (matchText(")")) {
            return FuncCall(name, args.toArray())
        }
        pos = save
        while (true) {
            args.add(parseOr())
            skipSpaces()
            let next = pos
            if (matchText(",")) {
                continue
            }
            pos = next
            if (matchText(")")) {
                break
            }
            fail("函数参数列表未闭合")
        }
        FuncCall(name, args.toArray())
    }
}
