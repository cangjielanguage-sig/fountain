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

/** Q3.8：`FieldGet/FieldSet/MethodCall/CtorCall` 解析 + 13/14 槽明确赋值/空安全。 */
@Test
public class AstM2_test {
    @TestCase
    public func parsesFourM2Constructors(): Unit {
        let reg = { n: String => n == 'User' }
        let get = Parser('{ u: User => u.age }', registered: reg).parseLambda()
        @Assert(AstShape.retShapeOf(get), 'field(var(u).age)')

        let set = Parser('{ u: User => u.age = 1 }', registered: reg).parseLambda()
        @Assert(AstShape.retShapeOf(set), 'fieldset(var(u).age = lit(1))')

        let call = Parser('{ u: User => u.save("x") }', registered: reg).parseLambda()
        @Assert(AstShape.retShapeOf(call), 'method(var(u).save [lit(x)])')

        let ctor = Parser('{ => User() }', registered: reg).parseLambda()
        @Assert(AstShape.retShapeOf(ctor), 'ctor(User [])')
    }

    /** 13/14 槽读未赋值 → NotAssigned（同句柄型规则）。 */
    @TestCase
    public func hostSlotsRequireAssignment(): Unit {
        @Assert(AstM2_test.errKind('{ => var cb: (Int64) -> Unit\n cb(1) }'),
            DiagKind.NOT_ASSIGNED)
        @Assert(AstM2_test.errKind('{ => var u: User\n u.age }'), DiagKind.NOT_ASSIGNED)
    }

    /** null 直存 13/14 槽 → NotAssigned（14 恒非空）。 */
    @TestCase
    public func nullIntoHostSlotsIsRejected(): Unit {
        @Assert(AstM2_test.errKind('{ => let u: User = null }'), DiagKind.NOT_ASSIGNED)
        @Assert(AstM2_test.errKind('{ => let cb: (Int64) -> Unit = null }'),
            DiagKind.NOT_ASSIGNED)
    }

    /** 正确赋值后可读（14 槽与句柄链）。 */
    @TestCase
    public func assignedHostSlotsAreReadable(): Unit {
        let unit = LowererM2_test.compileM2('{ => let u: User = User()\n u.age }')
        @Assert(unit.dir.at(0).retType, LocalType.I64)
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            let reg = { n: String => n == 'User' }
            let lam = Parser(src, registered: reg).parseLambda()
            let da = DefiniteAssignment(src, { _ => LocalType.NONE },
                isClassName: { n => n == 'User' })
            let _ = da.analyze(lam)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }
}
