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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException

/**
 * `localTypeOf` 引用缓存的护栏（`optimize-type-cache`）。
 *
 * 缓存是线程私有、跨 `JitFunction` 共享的：不同 `T` 交替调用时不能串味；
 * 未命中路径与命中路径必须给出同一个码。
 */
@Test
public class TypeCodeCache_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 不同 T 交替：`Int64`（0）与 `Bool`（2）不能互相命中。 */
    @TestCase
    public func alternatingTypesDoNotCross(): Unit {
        CompileCache.reset()
        let f1 = TypeCodeCache_test.compiler().compile('{ n: Int64 => n + 1 }')
        let f2 = TypeCodeCache_test.compiler().compile('{ n: Int64 => n > 0 }')
        var i = 0
        while (i < 100) {
            @Assert(f1.call<Int64>([Int64(i)]), Int64(i) + 1)
            @Assert(f2.call<Bool>([Int64(i)]), i > 0)
            i = i + 1
        }
    }

    /** 同 T 重复：结果稳定。 */
    @TestCase
    public func repeatedSameTypeIsStable(): Unit {
        CompileCache.reset()
        let f = TypeCodeCache_test.compiler().compile('{ n: Int64 => n * 2 }')
        var i = 0
        while (i < 1000) {
            @Assert(f.call<Int64>([Int64(i)]), Int64(i) * 2)
            i = i + 1
        }
    }

    /** 契约错误不被缓存改变：`call<Object>` 仍抛 19。 */
    @TestCase
    public func contractErrorUnchanged(): Unit {
        CompileCache.reset()
        let f = TypeCodeCache_test.compiler().compile('{ n: Int64 => n + 1 }')
        try {
            let _ = f.call<Object>([Int64(1)])
            @Fail('call<Object> 应抛 CALL_CONTRACT(19)')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
        }
        // 失败之后再调正确类型，仍应正常（缓存未被污染）。
        @Assert(f.call<Int64>([Int64(41)]), 42)
    }
}
