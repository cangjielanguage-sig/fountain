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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/**
 * S3.7 语法树与解析器（design-m1 §4.3.2 / §8.0）的失败用例。
 *
 * 断言形态：把 AST 折成紧凑的 s-表达式文本（见 `shape*` 系列），逐节点比对——
 * 比逐字段断言更能暴露结构错误，且一处改动不会连带几十处断言重写。
 */
@Test
public class Parser_test {

    // ==================================================================
    // lambda 源入口骨架（§8.0）
    // ==================================================================

    /** `{ => 1 }`：无参、尾表达式即返回值（隐式返回）。 */
    @TestCase
    public func minimalLambdaWithImplicitReturn(): Unit {
        let l = Parser('{ => 1 }').parseLambda()
        @Assert(l.params.size, 0)
        @Assert(l.body.size, 0)
        @Assert(AstShape.retShapeOf(l), 'lit(1)')
    }

    /** 形参 `name: Type`；槽位 = 参数序（`locals[0..nargs-1]`）。 */
    @TestCase
    public func paramsCarryTypesAndSlots(): Unit {
        let l = Parser('{ a: Int64, b: List<Int64> => a }').parseLambda()
        @Assert(l.params.size, 2)
        @Assert(l.params[0].name, 'a')
        @Assert(l.params[0].slot, 0)
        @Assert(l.params[1].name, 'b')
        @Assert(l.params[1].slot, 1)
        match (l.params[1].typeAnn) {
            case TypeRef.Builtin(code) => @Assert(code, LocalType.LIST)
            case _ => @Assert('unexpected type form', 'Builtin')
        }
    }

    /** `=>` 不可省略 → `MissingArrow`。 */
    @TestCase
    public func missingArrowIsRejected(): Unit {
        @Assert(expectParseError('{ a: Int64 a }').kind, DiagKind.MISSING_ARROW)
    }

    /** 不支持具名参数与参数默认值 → `BadParameterList`。 */
    @TestCase
    public func namedAndDefaultParametersAreRejected(): Unit {
        @Assert(expectParseError('{ a!: Int64 => a }').kind, DiagKind.BAD_PARAMETER_LIST)
        @Assert(expectParseError('{ a: Int64 = 1 => a }').kind, DiagKind.BAD_PARAMETER_LIST)
        @Assert(expectParseError('{ a: Nope => a }').kind, DiagKind.BAD_PARAMETER_LIST)
    }

    /** 源入口**必须且只能是**一个 lambda：尾部多余内容被拒。 */
    @TestCase
    public func trailingContentIsRejected(): Unit {
        @Assert(expectParseError('{ => 1 } 2').kind, DiagKind.SYNTAX_ERROR)
    }

    // ==================================================================
    // 语句与终结
    // ==================================================================

    /** 语句终结 = `;` 或换行；一行多条语句必须 `;`（design §4.3.1）。 */
    @TestCase
    public func statementTerminatorsAreSemiOrNewline(): Unit {
        let oneLine = Parser('{ => let a = 1; let b = 2\n a + b }').parseLambda()
        @Assert(oneLine.body.size, 2)
        @Assert(AstShape.shapeS(oneLine.body[0]), 'decl(a = lit(1))')
        @Assert(AstShape.shapeS(oneLine.body[1]), 'decl(b = lit(2))')
        @Assert(AstShape.retShapeOf(oneLine), '(+ var(a) var(b))')
        // 只有换行分隔时，第二段不会并进第一段（`a = 1` 换行 `-2` 不能被并成 `1 - 2`）
        let nl = Parser('{ =>\nlet a = 1\nlet b = 2\na + b\n}').parseLambda()
        @Assert(nl.body.size, 2)
    }

    /** 声明即首写；`let` / `var` 都可带类型注解（§11.7 类型集）。 */
    @TestCase
    public func declarationsMayCarryTypeAnnotations(): Unit {
        let l = Parser('{ => var x: Decimal = 1.5\n x }').parseLambda()
        @Assert(AstShape.shapeS(l.body[0]), 'decl(x : Decimal = lit(1.5))')
    }

    /** 控制流：`if` / `while` / `for-in`（含 `where`）/ `break` / `continue` / `return`。 */
    @TestCase
    public func controlFlowStatements(): Unit {
        let l = Parser('{ n: Int64 =>\n' +
            '  if (n > 0) { return n } else { return 0 - n }\n' +
            '}').parseLambda()
        @Assert(l.body.size, 1)
        @Assert(AstShape.shapeS(l.body[0]),
            'if (((> var(n) lit(0)))) block([return(var(n))]) else block([return((- lit(0) var(n)))])')

        let w = Parser('{ =>\nwhile (true) { break }\n1 }').parseLambda()
        @Assert(AstShape.shapeS(w.body[0]), 'while (lit(true)) block([break])')

        let f = Parser('{ m: Map<String, Int64> =>\n' +
            '  for ((k, v) in m where v > 0) { continue }\n' +
            '  1\n}').parseLambda()
        @Assert(AstShape.shapeS(f.body[0]),
            'forin(k,v in var(m) where (> var(v) lit(0))) block([continue])')
    }

    /** 多重赋值 `(a, b) = (b, a)`：`_` 忽略位仍是目标。 */
    @TestCase
    public func multiAssignAndUnderscoreTarget(): Unit {
        let l = Parser('{ =>\nvar a = 1\nvar b = 2\n(a, b) = (b, a)\n(_, b) = (a, a)\na }').parseLambda()
        @Assert(AstShape.shapeS(l.body[2]), 'multi((var(a),var(b)) = (var(b),var(a)))')
        @Assert(AstShape.shapeS(l.body[3]), 'multi((var(_),var(b)) = (var(a),var(a)))')
    }

    /** 容器变更是**赋值语句形态**（`list[i] = v` / `map[k] = v`，§9.15）。 */
    @TestCase
    public func containerMutationUsesAssignSyntax(): Unit {
        let l = Parser('{ list: List<Int64>, m: Map<String, Int64> =>\n' +
            '  list[0] = 7\n' +
            '  m["k"] = 1\n' +
            '  list\n}').parseLambda()
        @Assert(AstShape.shapeS(l.body[0]), 'assign(idxTarget[var(list),lit(0)] = lit(7))')
        @Assert(AstShape.shapeS(l.body[1]), 'assign(idxTarget[var(m),lit(k)] = lit(1))')
    }

    // ==================================================================
    // 表达式
    // ==================================================================

    /** 优先级与结合性：比较 < 加法 < 乘法；正则操作符高于加法、低于乘法（§11.9）。 */
    @TestCase
    public func precedenceFollowsTheFrozenOrder(): Unit {
        @Assert(AstShape.exprOf('{ => 1 + 2 * 3 }'), '(+ lit(1) (* lit(2) lit(3)))')
        @Assert(AstShape.exprOf('{ => 1 * 2 + 3 }'), '(+ (* lit(1) lit(2)) lit(3))')
        @Assert(AstShape.exprOf('{ => a == b && c }'), '(&& (== var(a) var(b)) var(c))')
        @Assert(AstShape.exprOf('{ => a ~ b + c }'), '(+ regexop(~ var(a) var(b)) var(c))')
        @Assert(AstShape.exprOf('{ => a * b ~ c }'), 'regexop(~ (* var(a) var(b)) var(c))')
        @Assert(AstShape.exprOf('{ => -a + b }'), '(+ (- var(a)) var(b))')
        @Assert(AstShape.exprOf('{ => a % b }'), '(% var(a) var(b))')
        @Assert(AstShape.exprOf('{ => a << b }'), '(<< var(a) var(b))')
    }

    /** 区间三形与 step；String 混合加法（一侧是字符串字面量 ⇒ `StrAdd`）。 */
    @TestCase
    public func rangeAndMixedStringAddition(): Unit {
        @Assert(AstShape.exprOf('{ => 1..10 }'), 'range(lit(1) .. lit(10))')
        @Assert(AstShape.exprOf('{ => 1..=10 : 2 }'), 'range(lit(1) ..= lit(10) : lit(2))')
        @Assert(AstShape.exprOf('{ => "a" + x }'), 'stradd(lit(a) var(x))')
        @Assert(AstShape.exprOf('{ => x + "a" }'), 'stradd(var(x) lit(a))')
    }

    /** 正则操作符与替换三形（§11.9「替换段词法」）。 */
    @TestCase
    public func regexOperatorsAndReplacementForms(): Unit {
        @Assert(AstShape.exprOf('{ => re ~ s }'), 'regexop(~ var(re) var(s))')
        @Assert(AstShape.exprOf('{ => re !~ s }'), 'regexop(!~ var(re) var(s))')
        @Assert(AstShape.exprOf('{ => re/s/r/g }'), 'regexop(/ var(re) var(s) var(r) g)')
        @Assert(AstShape.exprOf('{ => re/s/r/1 }'), 'regexop(/ var(re) var(s) var(r) n=1)')
        @Assert(AstShape.exprOf('{ => re/s/r/0,3 }'), 'regexop(/ var(re) var(s) var(r) n=0 m=3)')
        @Assert(AstShape.exprOf('{ => re/s/r }'), 'regexop(/ var(re) var(s) var(r) n=0)')
        // 除法不受影响（回退路径）
        @Assert(AstShape.exprOf('{ => a / b }'), '(/ var(a) var(b))')
    }

    /** 插值：`Interp` 的奇偶交替关系恒定（偶数 = 文本片段，奇数 = 表达式）。 */
    @TestCase
    public func interpolationSplitsIntoAlternatingParts(): Unit {
        // 偶数下标 = 文本片段，奇数下标 = 表达式片段（交替关系恒定）
        @Assert(AstShape.exprOf('{ => "a' + Parser_test.DOLLAR + '{x}b" }'), 'interp(lit(a),var(x),lit(b))')
        // 原始串不插值：`${` 是字面文本（§8.8）
        @Assert(AstShape.exprOf('{ => #"' + Parser_test.DOLLAR + '{x}"# }'), 'lit(' + Parser_test.DOLLAR + '{x})')
    }

    /** 空插值 → 编译错误（附 A.1「空的表达式片段 → 编译错误」）。 */
    @TestCase
    public func emptyInterpolationIsRejected(): Unit {
        @Assert(expectParseError('{ => "a' + Parser_test.DOLLAR + '{}" }').kind, DiagKind.SYNTAX_ERROR)
    }

    /** 嵌套闭包与立即调用 IIFE（§8.5）。 */
    @TestCase
    public func nestedClosuresAndIife(): Unit {
        let l = Parser('{ n: Int64 =>\nlet add = { y: Int64 => y + n }\nadd(n) }').parseLambda()
        @Assert(AstShape.shapeS(l.body[0]), 'decl(add = closure((y:Int64) => (+ var(y) var(n))))')
        @Assert(AstShape.retShapeOf(l), 'call(var(add) [var(n)])')
        @Assert(AstShape.exprOf('{ => {=> 42}() }'), 'iife(closure(() => lit(42)) [])')
    }

    /** `recursive`：调用位置与值位置（§8.0 v0.12）。 */
    @TestCase
    public func recursiveInCallAndValuePositions(): Unit {
        @Assert(AstShape.exprOf('{ n: Int64 => recursive(n - 1) }'),
            'call(recursive [(- var(n) lit(1))])')
        @Assert(AstShape.shapeS(Parser('{ => let f = recursive\nf }').parseLambda().body[0]),
            'decl(f = recursive)')
    }

    /** 空容器字面量与映射字面量；`{}` 与闭包的消歧（§3.3 v0.18）。 */
    @TestCase
    public func emptyContainerLiterals(): Unit {
        @Assert(AstShape.exprOf('{ => [] }'), 'list[]')
        @Assert(AstShape.exprOf('{ => {} }'), 'map{}')
        @Assert(AstShape.exprOf('{ => {"a": 1} }'), 'map{lit(a):lit(1)}')
        @Assert(AstShape.exprOf('{ => [1, 2] }'), 'list[lit(1),lit(2)]')
    }

    /** 一元 / 位 / 逻辑非与 `!~` 单 token。 */
    @TestCase
    public func unaryOperators(): Unit {
        @Assert(AstShape.exprOf('{ => !a }'), '(! var(a))')
        @Assert(AstShape.exprOf('{ => ~a }'), '(~ var(a))')
        @Assert(AstShape.exprOf('{ => -1 }'), '(- lit(1))')
    }

    /** AST 节点携带位置（design §4.3.2 位置链的第一环）。 */
    @TestCase
    public func nodesCarrySourcePosition(): Unit {
        let l = Parser('{ =>\n    let a = 1\n    a\n}').parseLambda()
        @Assert(l.body[0].pos().line, 2)
        @Assert(l.body[0].pos().column, 5)
        let rp = AstShape.retPosOf('{ =>\n    let a = 1\n    a\n}')
        @Assert(rp[0], 3)
    }

    /** 全构造器可达性：`Index` / `IndexTarget` / `MemberName` / `TupleLit` / `IfExpr` 的形状化。 */
    @TestCase
    public func everyConstructorHasAShape(): Unit {
        @Assert(AstShape.exprOf('{ xs: List<Int64> => xs[0] }'), 'index[var(xs),lit(0)]')
        @Assert(AstShape.exprOf('{ => (1, 2) }'), 'tuple(lit(1),lit(2))')
        // 值用法 if（必须有 else）
        @Assert(AstShape.shapeS(Parser('{ c: Bool => let x = if (c) { 1 } else { 2 }\nx }').parseLambda().body[0]),
            'decl(x = ifexpr((var(c)) lit(1) lit(2)))')
    }

    // ==================================================================
    // 形状化工具：全部移入 `AstShape.cj`（lib 编译单元——`*_test.cj` 里对递归 AST 枚举做
    // `match` 会读错 `Option` 载荷，见 AstShape.cj 文件头注释）。
    // ==================================================================

    /** 美元符号常量（被编译源码里的插值起始不能直写进仓颉字面量）。 */
    public static const DOLLAR: String = '$'

}

/** 期望解析期 fail-fast。 */
private func expectParseError(src: String): SourceCompileException {
    try {
        Parser(src).parseLambda()
    } catch (e: SourceCompileException) {
        return e
    }
    @Fail('期望解析期抛出 SourceCompileException')
}
