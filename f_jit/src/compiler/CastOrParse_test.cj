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
 * M2.2 语法：`E as T ?? F` 的解析形态与拒绝面。
 *
 * 断言用 `AstShape` 的 s-表达式（与 `Parser_test` 同口径）：`castor(<E> as <T> ?? <F>)`。
 * 语义（静态收窄）在 `CastOr_test` 里端到端验证，本文件只钉**语法**。
 */
@Test
public class CastOrParse_test {

    private static func parse(src: String): LambdaAst {
        Parser(src, registered: { n => n == 'User' || n == 'Admin' }).parseLambda()
    }

    /** 基本形态：`x as Int64 ?? 0` → `castor(var(x) as Int64 ?? lit(0))`。 */
    @TestCase
    public func castOrShapeIsRecognized(): Unit {
        @Assert(AstShape.exprOf('{ x: Int64 => x as Int64 ?? 0 }'),
            'castor(var(x) as Int64 ?? lit(0))')
    }

    /** `??` 是最低结合层：`a || b as Bool ?? true` 的左面是整个 `a || b`。 */
    @TestCase
    public func coalesceIsLooserThanOr(): Unit {
        @Assert(AstShape.exprOf('{ a: Bool, b: Bool => a || b as Bool ?? true }'),
            'castor((|| var(a) var(b)) as Bool ?? lit(true))')
    }

    /** `??` 右结合：`x as Int64 ?? y as Int64 ?? 0` 嵌套在右。 */
    @TestCase
    public func coalesceIsRightAssociative(): Unit {
        @Assert(AstShape.exprOf('{ x: Int64 => x as Int64 ?? y as Int64 ?? 0 }'),
            'castor(var(x) as Int64 ?? castor(var(y) as Int64 ?? lit(0)))')
    }

    /** 注册类名作目标类型（14）。`AstShape.exprOf` 不带 `registered` 谓词，故直接解析后取形状。 */
    @TestCase
    public func classTargetIsAccepted(): Unit {
        let l = CastOrParse_test.parse('{ u: User => u as User ?? u }')
        @Assert(AstShape.retShapeOf(l), 'castor(var(u) as User ?? var(u))')
    }

    /** 裸 `as`（无 `??`）合法：转型失败在运行期报错，不需要兜底。 */
    @TestCase
    public func bareAsIsRecognized(): Unit {
        @Assert(AstShape.exprOf('{ x: Int64 => x as Int64 }'), 'castor(var(x) as Int64)')
    }

    /** 裸 `??` → 语法错误：`??` 只作为 `as` 的兜底分隔符。 */
    @TestCase
    public func bareCoalesceIsRejected(): Unit {
        @Assert(CastOrParse_test.expectParseError('{ x: Int64 => x ?? 0 }').kind,
            DiagKind.SYNTAX_ERROR)
    }

    /** 未注册类名作 `as` 目标 → 与类型注解同一条错误（`BadParameterList`）。 */
    @TestCase
    public func unknownClassInAsIsRejected(): Unit {
        @Assert(CastOrParse_test.expectParseError('{ x: Int64 => x as Nope ?? x }').kind,
            DiagKind.BAD_PARAMETER_LIST)
    }

    /** 单 `?` 仍不是合法词法单元（没有引入新的一元运算符）。 */
    @TestCase
    public func singleQuestionMarkStaysIllegal(): Unit {
        @Assert(CastOrParse_test.expectParseError('{ x: Int64 => x ? 0 }').kind,
            DiagKind.ILLEGAL_CHARACTER)
    }

    private static func expectParseError(src: String): SourceCompileException {
        try {
            let _ = CastOrParse_test.parse(src)
        } catch (e: SourceCompileException) {
            return e
        }
        @Fail('期望解析期抛出 SourceCompileException')
    }
}
