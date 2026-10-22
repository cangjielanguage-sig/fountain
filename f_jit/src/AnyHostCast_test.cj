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
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectAnyHolder
import fountain::f_jit.test.ReflectUser

/**
 * A2 根包验收：14 目标的类界（P0-1）与返回位置逃逸槽的归还（P2-3）。
 *
 * 类界用例走**真实注册类**：`$as$ReflectUser` 由 `ReflectRegistrar` 在注册期合成，
 * 判定体走反射父链，因此「子类命中 / 无关类 22 / 向下转型 22」与非 Any 路径的 `is C`
 * 必须逐例一致。归还用例直接驱动 `JitFunction.releaseReturnHandle`（桥在 `call` 收尾
 * 调用的同一个函数），用 1000 轮对账表长。
 */
@Test
public class AnyHostCast_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ReflectUser>()
        c.registerType<ReflectAdmin>()
        c.registerType<ReflectAnyHolder>()
        c
    }

    /** `as C`：同型 / 上行命中，无关类与向下转型 22。 */
    @TestCase
    public func p0_1_asHostClassRespectsClassBoundary(): Unit {
        let c = AnyHostCast_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ a: Any => a as ReflectUser }')
        @Assert(f.call<ReflectUser>([ReflectUser('bob', 1)]).name, 'bob')
        @Assert(f.call<ReflectUser>([ReflectAdmin('root')]).name, 'root')
        @Assert(AnyHostCast_test.castCode(f, ReflectAnyHolder()), ErrCode.ANY_CAST)

        CompileCache.reset()
        let g = c.compile('{ a: Any => a as ReflectAdmin }')
        @Assert(g.call<ReflectAdmin>([ReflectAdmin('root')]).name, 'root')
        // 向下转型：静态是 ReflectUser、运行期是 ReflectUser ⇒ 不命中
        @Assert(AnyHostCast_test.castCode(g, ReflectUser('bob', 1)), ErrCode.ANY_CAST)
    }

    /** `is C`：Any 路径与非 Any 路径逐例一致。 */
    @TestCase
    public func p0_1_anyIsMatchesNonAnyIs(): Unit {
        let c = AnyHostCast_test.compiler()
        CompileCache.reset()
        let anyIs = c.compile('{ a: Any => a is ReflectAdmin }')
        CompileCache.reset()
        let plainIs = c.compile('{ u: ReflectUser => u is ReflectAdmin }')
        @Assert(anyIs.call<Bool>([ReflectAdmin('root')]), true)
        @Assert(plainIs.call<Bool>([ReflectAdmin('root')]), true)
        @Assert(anyIs.call<Bool>([ReflectUser('bob', 1)]), false)
        @Assert(plainIs.call<Bool>([ReflectUser('bob', 1)]), false)
        @Assert(anyIs.call<Bool>([ReflectAnyHolder()]), false)
    }

    /** 归还判定覆盖 15 与 16–19；闭包（12）不在此路径。 */
    @TestCase
    public func p2_3_returnHandleCodesCoverAnyAndJson(): Unit {
        @Assert(JitFunction.isReturnedHandle(LocalType.STRING), true)
        @Assert(JitFunction.isReturnedHandle(LocalType.HOST_OBJECT), true)
        @Assert(JitFunction.isReturnedHandle(LocalType.ANY), true)
        @Assert(JitFunction.isReturnedHandle(LocalType.JSON_VALUE), true)
        @Assert(JitFunction.isReturnedHandle(LocalType.JSON_NULL), true)
        @Assert(JitFunction.isReturnedHandle(LocalType.CLOSURE), false)
        @Assert(JitFunction.isReturnedHandle(LocalType.I64), false)
        @Assert(JitFunction.isReturnedHandle(LocalType.UNIT), false)
    }

    /**
     * P2-3：15 与 16–19 的逃逸返回各 1000 次「登记 → 逃逸 → 重置 → 归还」后，
     * 句柄表长度不随次数增长（复用 1 个槽），窗口已用数回到 0。
     */
    @TestCase
    public func p2_3_escapedAnyJsonSlotsReleased(): Unit {
        HandleTable.resetForTest()
        let base = HandleTable.slotCount()
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 1, dbgBase: 0)
        try {
            let codes = [LocalType.ANY, LocalType.JSON_VALUE, LocalType.JSON_OBJECT,
                LocalType.JSON_ARRAY, LocalType.JSON_NULL]
            var k = 0
            while (k < codes.size) {
                var i = 0
                while (i < 1000) {
                    HandleTable.openWindow(8)
                    let id = HandleTable.appendAnyBox(ctx, i)
                    HandleTable.escape(id)
                    HandleTable.resetWindow(-1)
                    @Assert(JitFunction.releaseReturnHandle(id, codes[k], None), true)
                    @Assert(HandleTable.isLiveHandle(id), false)
                    i = i + 1
                }
                @Assert(HandleTable.windowUsed(), 0)
                k = k + 1
            }
            @Assert(HandleTable.slotCount(), base + 1)
            @Assert(HandleTable.liveCount(), 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    private static func castCode(f: JitFunction, v: Any): Int64 {
        try {
            let _ = f.call<ReflectUser>([v])
            0
        } catch (e: JitException) {
            e.code
        }
    }
}
