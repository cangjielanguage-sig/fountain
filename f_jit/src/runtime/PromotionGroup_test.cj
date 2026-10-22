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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.TypeToken

/**
 * Q4.9 `PromotionGroup`（m2 §14.1/§14.2 / design §5.1.3）。
 *
 * 三规则：① 清单 + 幂等计数（双闭包共享捕获 ⇒ 计数 2）；② 释放链 = `close` 遍历 −1、归零
 * 释放（gen+1 可复用）；③ **路径 A 常量不入组、不释放**。`contains` 同时服务 `close` 与
 * 调用 `try/finally` 的**豁免判定**（提升槽不随普通清理释放）。
 */
@Test
public class PromotionGroup_test {
    private var ctx: ?JitContext = None

    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = Some(JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 1, dbgBase: 0))
    }

    private func teardown(): Unit {
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = None
    }

    private func alloc(s: String): Int64 {
        match (this.ctx) {
            case Some(c) => HandleTable.append(c, s, TypeToken.STRING)
            case None => 0
        }
    }

    /** `add` 幂等计数：双闭包共享同一捕获 ⇒ 计数 2（release 一次仍在组内）。 */
    @TestCase
    public func addIsIdempotentAndCounts(): Unit {
        setup()
        let id = alloc('shared')
        let g = PromotionGroup()
        g.add(id)
        g.add(id)
        @Assert(g.contains(id), true)
        @Assert(g.size(), 1)
        g.release(id)
        @Assert(g.contains(id), true) // 计数 2 → 1
        @Assert(HandleTable.isLiveHandle(id), true)
        g.release(id)
        @Assert(g.contains(id), false)
        @Assert(HandleTable.isLiveHandle(id), false) // 归零释放
        teardown()
    }

    /** 归零释放：gen+1 且槽位可复用（下一次分配取同一 idx、新 gen）。 */
    @TestCase
    public func releaseToZeroFreesAndBumpsGeneration(): Unit {
        setup()
        let id = alloc('v')
        let idx = HandleTable.idxOf(id)
        let gen = HandleTable.genOf(id)
        let g = PromotionGroup()
        g.add(id)
        g.release(id)
        @Assert(HandleTable.getAny(id).isNone(), true)
        let next = alloc('w')
        @Assert(HandleTable.idxOf(next), idx) // 释放后回到空闲链
        @Assert(HandleTable.genOf(next) > gen, true) // gen+1 ⇒ 旧 ID 永久失效
        teardown()
    }

    /** `contains`：未入组的活句柄 ⇒ false；`size` 反映清单规模。 */
    @TestCase
    public func containsOnlyGroupMembers(): Unit {
        setup()
        let a = alloc('a')
        let b = alloc('b')
        let g = PromotionGroup()
        g.add(a)
        @Assert(g.contains(a), true)
        @Assert(g.contains(b), false)
        @Assert(g.size(), 1)
        teardown()
    }

    /** 路径 A 常量不入组、不释放（有效期 = 单元存活期）。 */
    @TestCase
    public func constantsAreNeverPromotedOrReleased(): Unit {
        setup()
        let c = HandleTable.pinConst('const')
        let g = PromotionGroup()
        g.add(c)
        @Assert(g.contains(c), false)
        @Assert(g.size(), 0)
        g.release(c)
        @Assert(HandleTable.isLiveHandle(c), true)
        HandleTable.releaseConst(c)
        teardown()
    }

    /** `try/finally` 豁免：清理清单按 `contains` 跳过提升槽，只释放普通槽。 */
    @TestCase
    public func cleanupExemptsPromotedSlots(): Unit {
        setup()
        let promoted = alloc('p')
        let ordinary = alloc('o')
        let g = PromotionGroup()
        g.add(promoted)
        let cleanup = [ordinary, promoted]
        for (id in cleanup) {
            if (!g.contains(id)) {
                HandleTable.releaseEscaped(id)
            }
        }
        @Assert(HandleTable.isLiveHandle(promoted), true)
        @Assert(HandleTable.isLiveHandle(ordinary), false)
        teardown()
    }

    /** `add` 即原地提升：迁出窗口记账，窗口重置后仍可读且 ID/gen 不变。 */
    @TestCase
    public func addMovesSlotOutOfWindow(): Unit {
        setup()
        let id = alloc('keep')
        let gen = HandleTable.genOf(id)
        let before = HandleTable.windowUsed()
        let g = PromotionGroup()
        g.add(id)
        @Assert(HandleTable.windowUsed(), before - 1)
        HandleTable.resetWindow(-1)
        @Assert(HandleTable.getAny(id).isSome(), true)
        @Assert(HandleTable.genOf(id), gen)
        match (HandleTable.getAny(id)) {
            case Some(v) => match (v) { case s: String => @Assert(s, 'keep'); case _ => @Assert(1, 2) }
            case None => @Assert(1, 2)
        }
        teardown()
    }
}
