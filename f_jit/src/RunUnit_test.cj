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
import fountain::f_jit.compiler.PredefinedSnapshot
import fountain::f_jit.compiler.SourceCompiler

/** S6.9：`.fbc` 装载管线、整份 raw 去重、坏载荷拒绝。 */
@Test
public class RunUnit_test {
    @TestCase
    public func loadsAndRunsBytecode(): Unit {
        CompileCache.reset()
        let raw = RunUnit_test.rawOf('{ => 40 + 2 }')
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f = CompilePipeline.runUnit(raw, c)
        @Assert(f.call<Int64>(Array<Any>()), 42)
    }

    @TestCase
    public func sameBytesReuse(): Unit {
        CompileCache.reset()
        let raw = RunUnit_test.rawOf('{ => 5 }')
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let f1 = CompilePipeline.runUnit(raw, c)
        let runs = CompileCache.runs()
        let f2 = CompilePipeline.runUnit(raw, c)
        @Assert(CompileCache.runs(), runs)
        @Assert(f1.call<Int64>(Array<Any>()), 5)
        @Assert(f2.call<Int64>(Array<Any>()), 5)
    }

    @TestCase
    public func corruptedMagicIsRejected(): Unit {
        CompileCache.reset()
        let raw = RunUnit_test.rawOf('{ => 1 }')
        let bad = raw.clone()
        bad[0] = 0u8
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        var threw = false
        try {
            let _ = CompilePipeline.runUnit(bad, c)
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw, true)
    }

    private static func rawOf(src: String): Array<UInt8> {
        SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src).raw
    }
}
