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

/** S6.8：源码管线端到端、同源复用、编译期失败。 */
@Test
public class CompilePipeline_test {
    @TestCase
    public func endToEndConstant(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = c.compile('{ => 1 + 1 }')
        @Assert(f.call<Int64>(Array<Any>()), 2)
    }

    @TestCase
    public func endToEndWithArgs(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = c.compile('{ a: Int64 => a * 2 }')
        @Assert(f.call<Int64>([21]), 42)
    }

    @TestCase
    public func sameSourceReusesArtifact(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let src = '{ => 7 }'
        let f1 = c.compile(src)
        let runsAfterFirst = CompileCache.runs()
        let f2 = c.compile(src)
        @Assert(CompileCache.runs(), runsAfterFirst)
        @Assert(f1.call<Int64>(Array<Any>()), 7)
        @Assert(f2.call<Int64>(Array<Any>()), 7)
    }

    @TestCase
    public func compileErrorThrowsAtCompileTime(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        var threw = false
        try {
            let _ = c.compile('{ => 1 + }')
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw, true)
    }
}
