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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.TCase

/**
 * M3 R6.4（T40 对账）：deopt 重放 / 装箱 churn ×16 / 分配压力 / 跨线程只读盒。
 *
 * 口径：
 * - **重放**：见根包 `T40Deopt_test`（本包不能反向依赖根包的 `JitFunction`）；
 * - **churn**：装箱是**世界内分配**，必须计入窗口容量——容量 16 ⇒ 15 个盒之后第 16 个报 **16**；
 * - **压力**：句柄表强引用 ⇒ 大量分配后早期盒仍可读（环境无显式 GC 触发，这是代理口径）；
 * - **并发读**：frozen 盒的 `is` 只读、跨线程一致。
 */
@Test
public class T40Account_test {
    private static func setupWindow(cap: Int64, limit: Int64): JitContext {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 16
        HandleTable.capacityLimit = limit
        HandleTable.openWindow(cap)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: cap, fnId: 1, dbgBase: 0)
    }

    /**
     * 装箱 churn ×16：窗口容量 16 时，装箱按**世界内分配**记账（每盒 1 槽），
     * 第 16 个盒触顶 → 16；已分配的盒不受影响、仍可读。
     */
    @TestCase
    public func boxingChurnHonoursWindowCapacity(): Unit {
        let ctx = T40Account_test.setupWindow(16, 16)
        var first: Int64 = 0
        var i = 0
        while (i < 15) {
            let b = invokeHelper(ctx, 78, [Int64(LocalType.I64), i])
            @Assert(ctx.errCode, 0)
            if (i == 0) {
                first = b
            }
            i = i + 1
        }
        @Assert(HandleTable.windowUsed(), 15)
        // 第 16 个 → 窗口触顶
        let _ = invokeHelper(ctx, 78, [Int64(LocalType.I64), 99])
        @Assert(ctx.errCode, ErrCode.HANDLE_WINDOW_FULL)
        // 触顶不破坏已有盒
        ctx.errCode = 0
        @Assert(invokeHelper(ctx, 80, [first, Int64(LocalType.I64), 0xFFFF]), 0)
        @Assert(ctx.errCode, 0)
        @Assert(TCase.hit('T40/churn-16', true), true)
        JitContext.free(ctx)
    }

    /**
     * 分配压力（GC 代理口径）：连续 churn 后，最早那个盒仍可读且值不变。
     *
     * 环境不提供显式 GC 触发（std 无 `gc()` 入口），故以「大量分配 + 读回」证明
     * 句柄表持**强引用**、盒不会在调用之间被回收。
     */
    @TestCase
    public func boxSurvivesAllocationPressure(): Unit {
        let ctx = T40Account_test.setupWindow(256, 1048576)
        let keep = invokeHelper(ctx, 78, [Int64(LocalType.STRING), HandleTable.pin('keep')])
        @Assert(ctx.errCode, 0)
        var i = 0
        while (i < 400) {
            let b = invokeHelper(ctx, 78, [Int64(LocalType.I64), i])
            @Assert(ctx.errCode, 0)
            let _ = invokeHelper(ctx, 80, [b, Int64(LocalType.I64), 0xFFFF])
            @Assert(ctx.errCode, 0)
            i = i + 1
        }
        let back = invokeHelper(ctx, 80, [keep, Int64(LocalType.STRING), 0xFFFF])
        @Assert(ctx.errCode, 0)
        @Assert(HandleTable.fetchString(back), 'keep')
        @Assert(TCase.hit('T40/alloc-pressure', true), true)
        JitContext.free(ctx)
    }

    /** 跨线程只读盒：frozen 盒的 `is` 并发调用结果一致、无错误码。 */
    @TestCase
    public func readOnlyBoxIsThreadSafe(): Unit {
        let ctx = T40Account_test.setupWindow(128, 1048576)
        let h = invokeHelper(ctx, 78, [Int64(LocalType.I64), 7])
        @Assert(ctx.errCode, 0)
        HandleTable.markFrozen(h)
        let base = HandleTable.windowBaseOf()
        let f1 = spawn {
            let c = JitContext.create(hwBase: base, hwCap: 128, fnId: 1, dbgBase: 0)
            let r = invokeHelper(c, 79, [h, Int64(LocalType.I64), 0xFFFF])
            let code = c.errCode
            JitContext.free(c)
            (r, code)
        }
        let f2 = spawn {
            let c = JitContext.create(hwBase: base, hwCap: 128, fnId: 1, dbgBase: 0)
            let r = invokeHelper(c, 79, [h, Int64(LocalType.STRING), 0xFFFF])
            let code = c.errCode
            JitContext.free(c)
            (r, code)
        }
        let (r1, c1) = f1.get()
        let (r2, c2) = f2.get()
        @Assert(c1, 0)
        @Assert(c2, 0)
        @Assert(r1, 1)
        @Assert(r2, 0)
        @Assert(TCase.hit('T40/thread-readonly', true), true)
        JitContext.free(ctx)
    }
}
