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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException

/** Q3.1：类型记法解析（m2 §3 / §16.1）。 */
@Test
public class TypeRef_test {
    /** 内建 / 函数类型 / 注册类名三类记法。 */
    @TestCase
    public func parsesThreeForms(): Unit {
        let l = Parser('{ a: Int64, b: (Int64, String) -> Bool, c: User => a }',
            registered: { n => n == 'User' }).parseLambda()
        @Assert(l.params.size, 3)
        @Assert(l.params[0].typeAnn.code(), LocalType.I64)
        @Assert(AstShape.builtinName(l.params[0].typeAnn), 'Int64')
        @Assert(l.params[1].typeAnn.code(), LocalType.HOST_CLOSURE)
        @Assert(AstShape.builtinName(l.params[1].typeAnn), '(Int64,String) -> Bool')
        @Assert(l.params[1].typeAnn.hostRet(), LocalType.BOOL)
        @Assert(l.params[2].typeAnn.code(), LocalType.HOST_OBJECT)
        @Assert(AstShape.builtinName(l.params[2].typeAnn), 'User')
    }

    /** 无参函数类型 `() -> R`。 */
    @TestCase
    public func parsesZeroArgClosureType(): Unit {
        let l = Parser('{ f: () -> Unit => 1 }').parseLambda()
        @Assert(l.params[0].typeAnn.code(), LocalType.HOST_CLOSURE)
        @Assert(AstShape.builtinName(l.params[0].typeAnn), '() -> Unit')
    }

    /**
     * 14 位置的**类名必须进 AST**（GAP-04/GAP-05 的前提）。
     *
     * `(User) -> User` 与 `(User) -> Order` 的类别码完全相同（`[14] -> 14`）；只靠码无法区分，
     * 签名注册表（`JitHost.registerSignature`）按「码 + 类名」查 id，因此 AST 必须保留类名。
     */
    @TestCase
    public func keepsClassNameInSignature(): Unit {
        let l = Parser('{ f: (User) -> User, g: (User) -> Order => 1 }',
            registered: { n => n == 'User' || n == 'Order' }).parseLambda()
        @Assert(l.params[0].typeAnn.hostParams().size, 1)
        @Assert(l.params[0].typeAnn.hostParams()[0], LocalType.HOST_OBJECT)
        @Assert(l.params[0].typeAnn.hostParamNames().size, 1)
        @Assert(l.params[0].typeAnn.hostParamNames()[0], 'User')
        @Assert(l.params[0].typeAnn.hostRet(), LocalType.HOST_OBJECT)
        @Assert(l.params[0].typeAnn.hostRetName(), 'User')
        @Assert(l.params[1].typeAnn.hostRetName(), 'Order')
        @Assert(AstShape.builtinName(l.params[0].typeAnn), '(User) -> User')
        @Assert(AstShape.builtinName(l.params[1].typeAnn), '(User) -> Order')
    }

    /** T/R 合法集 0–8/10–11/14：9（Regex）、12（Closure）拒绝。 */
    @TestCase
    public func rejectsIllegalSignatureComponents(): Unit {
        @Assert(TypeRef_test.errKind('{ f: (Regex) -> Int64 => 1 }'),
            DiagKind.BAD_PARAMETER_LIST)
        @Assert(TypeRef_test.errKind('{ f: (Int64) -> Regex => 1 }'),
            DiagKind.BAD_PARAMETER_LIST)
        @Assert(TypeRef_test.errKind('{ f: (Closure) -> Int64 => 1 }'),
            DiagKind.BAD_PARAMETER_LIST)
    }

    /** 禁高阶：T/R 出现函数类型即拒绝。 */
    @TestCase
    public func rejectsHigherOrder(): Unit {
        @Assert(TypeRef_test.errKind('{ f: ((Int64) -> Bool) -> Unit => 1 }'),
            DiagKind.BAD_PARAMETER_LIST)
        @Assert(TypeRef_test.errKind('{ f: (Int64) -> (Int64) -> Bool => 1 }'),
            DiagKind.BAD_PARAMETER_LIST)
    }

    /** 未注册类名 → 编译错误（消息含类名）。 */
    @TestCase
    public func rejectsUnknownClassName(): Unit {
        @Assert(TypeRef_test.errKind('{ a: Nope => a }'), DiagKind.BAD_PARAMETER_LIST)
        @Assert(TypeRef_test.errText('{ a: Nope => a }').contains('Nope'), true)
        @Assert(TypeRef_test.errText('{ a: Nope => a }').contains('未注册'), true)
    }

    /** 函数类型缺 `->`。 */
    @TestCase
    public func rejectsMissingArrow(): Unit {
        @Assert(TypeRef_test.errKind('{ f: (Int64) Bool => 1 }'), DiagKind.BAD_PARAMETER_LIST)
    }

    /** 已注册类名可作 T/R（14 合法；签名编码只记类型码）。 */
    @TestCase
    public func acceptsRegisteredClassInSignature(): Unit {
        let l = Parser('{ f: (User) -> User => 1 }', registered: { n => n == 'User' }).parseLambda()
        @Assert(l.params[0].typeAnn.code(), LocalType.HOST_CLOSURE)
        @Assert(l.params[0].typeAnn.hostRet(), LocalType.HOST_OBJECT)
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            let _ = Parser(src).parseLambda()
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            let _ = Parser(src).parseLambda()
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }
}
