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
import fountain::f_jit.runtime.HandleTable

/**
 * 卸载与编译缓存的关系（本变更 H2）。
 *
 * `unload()` 是**单元**级终态：缓存必须同步逐出，否则同源再编译会命中已卸载的旧单元，
 * 任何调用都以 19 失败。包装实例上的 `unload()` 是**闭包**级释放：只放掉提升组，缓存必须保留。
 */
@Test
public class refineUnload_test {

    private static let UNIT_SRC = '{ n: Int64 => n + 1 }'
    private static let CLOSURE_SRC = '{ => let f = { x: Int64 => x + 1 }\n f }'

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 卸载后同源再编译：必须重跑管线并返回可用的新单元（缓存里那份已死）。 */
    @TestCase
    public func unloadEvictsUnitFromCache(): Unit {
        CompileCache.reset()
        let c = refineUnload_test.compiler()
        let u1 = c.compile(refineUnload_test.UNIT_SRC)
        @Assert(u1.call<Int64>([41]), 42)
        @Assert(CompileCache.runs(), 1)
        @Assert(u1.unload(), true)
        // 逐出证据：同源再编译必须重新认领管线（旧实现会直接命中缓存，runs 停在 1）
        let u2 = c.compile(refineUnload_test.UNIT_SRC)
        @Assert(CompileCache.runs(), 2)
        @Assert(u2.call<Int64>([1]), 2)
        // 旧句柄仍是终态
        var code: Int64 = 0
        try {
            let _ = u1.call<Int64>([1])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
    }

    /** 重复卸载幂等，且只逐出一次（不会把重编后的新单元误删）。 */
    @TestCase
    public func repeatedUnloadEvictsOnce(): Unit {
        CompileCache.reset()
        let c = refineUnload_test.compiler()
        let u1 = c.compile(refineUnload_test.UNIT_SRC)
        @Assert(u1.unload(), true)
        @Assert(u1.unload(), true)
        let u2 = c.compile(refineUnload_test.UNIT_SRC)
        @Assert(CompileCache.runs(), 2)
        // 二次 unload 已不持键，不得影响新单元
        @Assert(u2.call<Int64>([2]), 3)
        @Assert(CompileCache.runs(), 2)
    }

    /**
     * 包装实例的 `unload()` **不得**逐出单元：它只释放该闭包的提升组，单元仍然可用，
     * 同源再编译必须命中缓存（否则每次取闭包都会重编一份）。
     */
    @TestCase
    public func closureUnloadKeepsUnitInCache(): Unit {
        HandleTable.resetForTest()
        CompileCache.reset()
        let c = refineUnload_test.compiler()
        let unit = c.compile(refineUnload_test.CLOSURE_SRC)
        @Assert(CompileCache.runs(), 1)
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([41]), 42)
        w.unload()
        @Assert(w.isClosed, true)
        let again = c.compile(refineUnload_test.CLOSURE_SRC)
        @Assert(CompileCache.runs(), 1)
        @Assert(again.call<JitClosureId>([]).id > 0, true)
    }
}
