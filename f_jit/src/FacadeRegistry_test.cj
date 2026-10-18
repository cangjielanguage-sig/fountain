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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/** P6.1 / P6.2：`CompileOptions`、`PredefinedFunction` 与 `Compiler` 注册表。 */
@Test
public class FacadeRegistry_test {

    @TestCase
    public func optionsDefaults(): Unit {
        let opts = CompileOptions(DummyDiagnosticsSink())
        @Assert(opts.jit, JitMode.Auto)
        @Assert(opts.cpuFeatures, 0u64)
    }

    @TestCase
    public func predefinedRejectsIllegalTypes(): Unit {
        var code: Int64 = 0
        var site: Int64 = 0
        try {
            let _ = PredefinedFunction('bad', [LocalType.CLOSURE], LocalType.I64, { _ => 0 })
        } catch (e: JitException) {
            code = e.code
            site = e.site
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(site, -1)

        var code2: Int64 = 0
        try {
            let _ = PredefinedFunction('bad2', [LocalType.I64], 13u16, { _ => 0 })
        } catch (e: JitException) {
            code2 = e.code
        }
        @Assert(code2, ErrCode.CALL_CONTRACT)
    }

    @TestCase
    public func registerQueryUnregister(): Unit {
        // T23/ 映射标签（check_tmap 断言级校验）
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = PredefinedFunction('add', [LocalType.I64, LocalType.I64], LocalType.I64,
            { a => a[0] })
        c.registerFunction(f)
        @Assert(c.hasFunction('add'), true)
        @Assert(c.hasFunction('nope'), false)
        let names = c.registeredNames()
        @Assert(names.size, 1)
        @Assert(names[0], 'add')
        @Assert(c.snapshot().size(), 1)
        @Assert(c.unregisterFunction('add'), true)
        @Assert(c.unregisterFunction('add'), false)
        @Assert(c.hasFunction('add'), false)
        @Assert(c.snapshot().size(), 0)
    }

    @TestCase
    public func duplicateIsRejected(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = PredefinedFunction('dup', [], LocalType.UNIT, { _ => () })
        c.registerFunction(f)
        var kind = ''
        try {
            c.registerFunction(f)
        } catch (e: SourceCompileException) {
            kind = e.kind
        }
        @Assert(kind, 'DuplicateRegistration')
    }

    @TestCase
    public func maxPredefinedIsEnforced(): Unit {
        let c = Compiler('c', CompileOptions(DummyDiagnosticsSink()), 1)
        c.registerFunction(PredefinedFunction('a', [], LocalType.UNIT, { _ => () }))
        var kind = ''
        try {
            c.registerFunction(PredefinedFunction('b', [], LocalType.UNIT, { _ => () }))
        } catch (e: SourceCompileException) {
            kind = e.kind
        }
        @Assert(kind, 'NotImpl')
    }
}
