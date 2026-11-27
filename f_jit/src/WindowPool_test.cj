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
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.RuntimeEnv

/**
 * 窗口对象复用的护栏（`optimize-call-alloc`）。
 *
 * 复用 `Win` 时若漏清 `used` / `appendIds` / `pins`，会表现为「新窗口带着上一次的记账」；
 * 这里用连续开合与活槽计数锁住。
 */
@Test
public class WindowPool_test {

    /** 连续 1000 次开合：容量正确、已用数归零、环境窗口复原。 */
    @TestCase
    public func repeatedOpenResetKeepsState(): Unit {
        let rs = RuntimeEnv.current()
        HandleTable.openWindow(64)
        HandleTable.resetWindow(-1)
        var i = 0
        while (i < 1000) {
            let (_, c) = HandleTable.openWindowWith(rs, 64)
            @Assert(c, 64)
            @Assert(HandleTable.windowUsed(), 0)
            HandleTable.resetWindow(rs, -1)
            i = i + 1
        }
        @Assert(HandleTable.windowCapOf(), HandleTable.initialCapacity)
    }

    /** 连续开合不泄漏活槽（reset 的释放行为不变）。 */
    @TestCase
    public func liveCountReturnsToBaseline(): Unit {
        let before = HandleTable.liveCount()
        let rs = RuntimeEnv.current()
        var i = 0
        while (i < 1000) {
            let (_, c) = HandleTable.openWindowWith(rs, 128)
            @Assert(c, 128)
            HandleTable.resetWindow(rs, -1)
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), before)
    }

    /** 池复用的窗口必须从「已用数 0」开始（不能带上一次调用的记账）。 */
    @TestCase
    public func reusedWindowStartsClean(): Unit {
        let rs = RuntimeEnv.current()
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        try {
            HandleTable.openWindow(128)
            HandleTable.syncTo(ctx, rs)
            let _ = HandleTable.append(ctx, 'pool-probe', TypeToken.STRING)
            @Assert(HandleTable.windowUsed(), 1)
            HandleTable.resetWindow(rs, -1)
            let (_, c) = HandleTable.openWindowWith(rs, 128)
            @Assert(c, 128)
            @Assert(HandleTable.windowUsed(), 0)
            HandleTable.resetWindow(rs, -1)
        } finally {
            JitContext.free(ctx, rs)
        }
    }
}
