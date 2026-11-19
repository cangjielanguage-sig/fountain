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
import fountain::f_jit.base.DummyDiagnosticsSink

/**
 * 成员访问的**"确实走了 JIT"**守卫（`Inheritance_test` / `Interface_test` 只验语义）。
 *
 * 语义测试与回退路径是解耦的：整单元退回解释器时结果同样正确，只有性能下降 ⇒
 * 必须额外断言 `isJitBacked()`，否则"支持"可能只是解释器在兜底。
 *
 * 覆盖三类：
 * 1. 子类对象访问**父类**成员（字段 + 方法 + 自有成员混合）；
 * 2. 接口形参访问**接口自身**成员；
 * 3. **子接口**类型变量访问**父接口**成员（`ProbeGreeter <: ProbeNamed`）。
 */
@Test
public class JitMemberAccess_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ProbeBase>()
        c.registerType<ProbeDerived>()
        c.registerInterface<ProbeNamed>()
        c.registerInterface<ProbeGreeter>()
        c.registerType<ProbeGreeterImpl>()
        c
    }

    /** 场景 1：子类访问父类字段与方法（`x.m() + x.f + x.d`）。 */
    @TestCase
    public func derivedReadsParentMembersUnderJit(): Unit {
        CompileCache.reset()
        let f = JitMemberAccess_test.compiler().compile(
            '{ x: ProbeDerived => x.m() + x.f + x.d }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([ProbeDerived()]), 13) // 10 + 1 + 2
    }

    /** 场景 1（仅父方法）：确认父类方法本身也可在子类型上直调。 */
    @TestCase
    public func derivedCallsParentMethodUnderJit(): Unit {
        CompileCache.reset()
        let f = JitMemberAccess_test.compiler().compile('{ x: ProbeDerived => x.m() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([ProbeDerived()]), 10)
    }

    /** 场景 2：接口形参访问接口自身成员。 */
    @TestCase
    public func interfaceOwnMemberUnderJit(): Unit {
        CompileCache.reset()
        let f = JitMemberAccess_test.compiler().compile('{ g: ProbeGreeter => g.greet() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<String>([ProbeGreeterImpl()]), 'hello')
    }

    /** 场景 3：**子接口**类型变量访问**父接口**成员（`name()` 来自 `ProbeNamed`）。 */
    @TestCase
    public func subInterfaceReadsParentMemberUnderJit(): Unit {
        CompileCache.reset()
        let f = JitMemberAccess_test.compiler().compile('{ g: ProbeGreeter => g.name() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<String>([ProbeGreeterImpl()]), 'impl')
    }
}
