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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod

/**
 * 编译失败缓存的失效与有界化（`fix-compile-failure-cache-sticky`）。
 *
 * 两条底线：
 * 1. **注册表变了，旧的失败结论必须失效**——否则「先编译、失败、补注册、重试」这条
 *    宿主最常见的使用路径在第一次失败后就永久走不通（失败单元没有 `close`，
 *    `failures` 永远不会被清）。
 * 2. **`failures` 必须有界**——它按源码指纹累积，长期运行的服务持续喂新源码时会无限增长。
 */
@Test
public class CompileFailureCache_test {
    /** 未注册类导致失败 → 补注册 → 同源码必须能编出来。 */
    @TestCase
    public func registrationInvalidatesFailure(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let src = '{ u: LateCls => u.m(1) }'
        var firstOk = false
        try {
            let _ = c.compile(src)
            firstOk = true
        } catch (e: Exception) {
            firstOk = false
        }
        @Assert(firstOk, false) // 首次必须失败（未注册类）
        let pf = PredefinedFunction('LateCls.m', [LocalType.HOST_OBJECT, LocalType.I64],
            LocalType.I64, { _ => Int64(1) })
        c.registerClass(ClassDescriptor(name: 'LateCls', fields: Array<PublicField>(),
            methods: [PublicMethod(name: 'm', bind: pf)], ctors: Array<PublicCtor>()))
        // 注册表已变：同源码必须重编成功（旧实现会复述「未注册的类名」）。
        let f = c.compile(src)
        @Assert(f.isJitBacked(), true)
        let _ = f.close(0)
        CompileCache.reset()
    }

    /** 失败条目有上限：连续 300 个不同失败源码后，`failureCount()` 不超过 256。 */
    @TestCase
    public func failureCacheIsBounded(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        var i = 0
        while (i < 300) {
            try {
                let _ = c.compile('{ x: Int64 => x + ${i} + }')
            } catch (e: Exception) {
                ()
            }
            i = i + 1
        }
        @Assert(CompileCache.failureCount() > 0, true)
        @Assert(CompileCache.failureCount() <= 256, true)
        CompileCache.reset()
    }
}
