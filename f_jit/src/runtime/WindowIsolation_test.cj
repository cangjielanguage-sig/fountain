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

import std.collection.ArrayList
import std.collection.HashMap
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * 并行调用的**窗口/迭代器隔离**用例（`feat-f-jit-parallel-call` P1.1/P1.4）。
 *
 * 这些用例绕过 `JitFunction.call`（仍被 `callMtx` 串行），直接并发调用 `HandleTable` /
 * `IterTable` 的公开 API —— 串行化层挡不住它们，因此能真正钉住「窗口记账是否线程私有」。
 */
@Test
public class WindowIsolation_test {

    private static func ctxOf(cap: Int64): JitContext {
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: cap, fnId: 1, dbgBase: 0)
    }

    /**
     * 两线程各自开窗、各自追加 32 槽：每个线程看到的 `windowUsed` 只能是自己的计数，
     * 且收尾后活槽回到基线。
     *
     * 旧实现只有一张全局窗口：任一线程 `openWindow` 都会清掉对方的记账，`windowUsed`
     * 变成两线程之和（或更早被清零）——本用例必红。
     */
    @TestCase
    public func concurrentWindowsKeepSeparateAccounting(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 8
        HandleTable.capacityLimit = 1048576
        let baseLive = HandleTable.liveCount()
        let arrive = AtomicInt64(0)
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 2) {
            let tag = Int64(t)
            futures.add(spawn {
                HandleTable.openWindow(8)
                let ctx = WindowIsolation_test.ctxOf(8)
                let _ = arrive.fetchAdd(1)
                while (arrive.load() < 2) {}
                var wrong = 0
                var i = 0
                while (i < 32) {
                    let id = HandleTable.append(ctx, 'w${tag}-${i}', TypeToken.STRING)
                    if (!HandleTable.isLiveHandle(id)) {
                        wrong = wrong + 1
                    }
                    if (HandleTable.windowUsed() != i + 1) {
                        wrong = wrong + 1000
                    }
                    i = i + 1
                }
                if (HandleTable.windowUsed() != 32) {
                    wrong = wrong + 100000
                }
                HandleTable.resetWindow(-1)
                JitContext.free(ctx)
                wrong
            })
            t = t + 1
        }
        for (x in futures) {
            @Assert(x.get(), 0)
        }
        @Assert(HandleTable.liveCount(), baseLive)
        @Assert(HandleTable.windowUsed(), 0)
    }

    /**
     * 窗口收尾只按「代数仍匹配」释放：A 线程窗口里的槽被显式归还、又被 B 线程复用后，
     * A 的 `resetWindow` 不得把 B 的新槽一并杀掉。
     *
     * 这是 `owned` 存 ID（而非索引）的理由；按索引释放的实现会在这里红。
     */
    @TestCase
    public func resetWindowDoesNotKillSlotReusedByAnotherThread(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 8
        HandleTable.capacityLimit = 1048576
        let aReleased = AtomicInt64(0)
        let bPinned = AtomicInt64(0)
        // 跨线程写回用单元素数组（仓颉闭包不捕获可变局部变量）。
        let bId = Array<Int64>(1, repeat: 0)
        let b = spawn {
            // B 等到 A 释放后再 pin，确保拿到 A 刚归还的那个索引。
            while (aReleased.load() == 0) {}
            bId[0] = HandleTable.pin('reused-by-b')
            let _ = bPinned.fetchAdd(1)
            0
        }
        // A：开窗 → 分配 → 显式归还 → 通知 B → 等 B 复用 → 收尾。
        HandleTable.openWindow(8)
        let ctx = WindowIsolation_test.ctxOf(8)
        let idA = HandleTable.append(ctx, 'owned-by-a', TypeToken.STRING)
        HandleTable.release(idA)
        let _ = aReleased.fetchAdd(1)
        while (bPinned.load() == 0) {}
        HandleTable.resetWindow(-1)
        JitContext.free(ctx)
        @Assert(b.get(), 0)
        @Assert(HandleTable.isLiveHandle(bId[0]), true)
        @Assert(HandleTable.getAny(bId[0]).isSome(), true)
        HandleTable.release(bId[0])
    }

    /**
     * 迭代器表线程私有：工作线程持有 1 个游标时，主线程看到的 `liveCount` 必须是 0。
     *
     * 旧实现是全局表（带全局锁），主线程会看到 1 —— 本断言即红。
     */
    @TestCase
    public func iterTablesAreThreadPrivate(): Unit {
        HandleTable.resetForTest()
        let map = HashMap<ConstMapKey, Any>()
        var i = 0
        while (i < 64) {
            map.add(ConstMapKey(Int64(i), 'k${i}'), Int64(i))
            i = i + 1
        }
        let h = HandleTable.pin(map)
        let opened = AtomicInt64(0)
        let done = AtomicInt64(0)
        let w = spawn {
            let cur = IterTable.open(h, 0u8)
            let _ = opened.fetchAdd(1)
            var seen = 0
            while (IterTable.next(cur)) {
                let _ = IterTable.key(cur)
                let _ = IterTable.value(cur)
                seen = seen + 1
            }
            IterTable.close(cur)
            if (IterTable.liveCount() != 0) {
                seen = -1
            }
            let _ = done.fetchAdd(1)
            seen
        }
        while (opened.load() == 0) {}
        // 工作线程的游标对主线程不可见。
        @Assert(IterTable.liveCount(), 0)
        while (done.load() == 0) {}
        @Assert(w.get(), 64)
        @Assert(IterTable.liveCount(), 0)
        HandleTable.release(h)
    }
}
