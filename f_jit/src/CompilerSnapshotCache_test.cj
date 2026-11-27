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
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.LocalType

/**
 * `Compiler.snapshot()` 缓存的失效语义（`optimize-compile-path` C2）。
 *
 * 缓存必须满足：注册后**下一次编译**立即可见、注销后立即不可见。
 * 这两条也是缓存最容易出错的地方（忘了失效 ⇒ 新注册静默不生效）。
 */
@Test
public class CompilerSnapshotCache_test {
    @TestCase
    public func registrationInvalidatesCachedSnapshot(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerFunction(PredefinedFunction('snapA', [LocalType.I64], LocalType.I64, { _ => 1 }))
        // 第一次编译：建立并缓存快照
        let f1 = c.compile('{ => snapA(1) }')
        @Assert(f1.call<Int64>([]), 1)
        // 再注册一个函数：缓存必须失效，否则下面这行会「未知函数」失败
        c.registerFunction(PredefinedFunction('snapB', [LocalType.I64], LocalType.I64, { _ => 2 }))
        let f2 = c.compile('{ => snapB(1) }')
        @Assert(f2.call<Int64>([]), 2)
        CompileCache.reset()
    }

    @TestCase
    public func unregistrationInvalidatesCachedSnapshot(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerFunction(PredefinedFunction('snapC', [LocalType.I64], LocalType.I64, { _ => 3 }))
        let f = c.compile('{ => snapC(1) }')
        @Assert(f.call<Int64>([]), 3)
        @Assert(c.unregisterFunction('snapC'), true)
        var failed = false
        try {
            let _ = c.compile('{ => snapC(2) }')
        } catch (_: Exception) {
            failed = true
        }
        @Assert(failed, true)
        CompileCache.reset()
    }
}
