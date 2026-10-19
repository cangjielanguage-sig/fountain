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
 * Q4.10 `HandleTable` 条目标签扩展 + 提升协作（m2 §1/§11/§14）。
 *
 * - tag 10 `HostCallback` / tag 11 宿主类实例：`pin`（同对象同 ID）/ `fetch` / `get` 三向往返；
 * - `moveOutGroup`：**原地提升**——ID/gen 不变、不参与后续分配重用、迁出窗口记账；
 * - **槽级（免级联）**：捕获容器时只迁出容器那 1 槽，元素（宿主原生引用）不被触碰。
 */
@Test
public class HandleTableM2_test {
    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
    }

    private func ctx(): JitContext {
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
    }

    /** tag 10：HostCallback 的 pin / fetch / get 往返；同对象同 ID。 */
    @TestCase
    public func hostCallbackTagRoundTrip(): Unit {
        setup()
        let cb = HostCallback({ x: Int64 => x })
        let a = HandleTable.pin(cb)
        let b = HandleTable.pin(cb)
        @Assert(a, b)
        @Assert(HandleTable.tagOf(a), TypeToken.HOST_CLOSURE)
        @Assert(HandleTable.isType(a, TypeToken.HOST_CLOSURE), true)
        @Assert(refEq(HandleTable.fetchHostCallback(a), cb), true)
        match (HandleTable.getAs(a, TypeToken.HOST_CLOSURE)) {
            case Some(v) => match (v) { case got: HostCallback => @Assert(refEq(got, cb), true); case _ => @Assert(1, 2) }
            case None => @Assert(1, 2)
        }
        @Assert(HandleTable.getAs(a, TypeToken.STRING).isNone(), true)
    }

    /** tag 11：宿主类实例的 pin / fetch / get 往返；同对象同 ID + 引用身份。 */
    @TestCase
    public func hostObjectTagRoundTrip(): Unit {
        setup()
        let probe = FieldProbe()
        let a = HandleTable.pinHostObject(probe)
        let b = HandleTable.pinHostObject(probe)
        @Assert(a, b)
        @Assert(HandleTable.tagOf(a), TypeToken.HOST_OBJECT)
        @Assert(HandleTable.tagOf(a), 11u16) // 与 M3 JSON 句柄复用同 tag，不新开
        @Assert(HandleTable.isType(a, TypeToken.HOST_OBJECT), true)
        @Assert(refEq(HandleTable.fetchHostObject(a), probe), true)
        match (HandleTable.getAny(a)) {
            case Some(v) => match (v) { case got: FieldProbe => @Assert(refEq(got, probe), true); case _ => @Assert(1, 2) }
            case None => @Assert(1, 2)
        }
        match (HandleTable.getAs(a, TypeToken.HOST_OBJECT)) {
            case Some(v) => match (v) { case got: FieldProbe => @Assert(refEq(got, probe), true); case _ => @Assert(1, 2) }
            case None => @Assert(1, 2)
        }
        @Assert(HandleTable.getAs(a, TypeToken.STRING).isNone(), true)
    }

    /**
     * `moveOutGroup`：窗口记账迁出、ID/gen 不变、窗口重置后仍可用、不参与后续分配重用；
     * 重复调用幂等（不重复扣减）。
     */
    @TestCase
    public func moveOutGroupPromotesInPlace(): Unit {
        setup()
        let c = ctx()
        try {
            let a = HandleTable.append(c, 'promoted', TypeToken.STRING)
            let b = HandleTable.append(c, 'ordinary', TypeToken.STRING)
            let gen = HandleTable.genOf(a)
            let before = HandleTable.windowUsed()
            HandleTable.moveOutGroup([a])
            @Assert(HandleTable.windowUsed(), before - 1)
            HandleTable.moveOutGroup([a]) // 幂等
            @Assert(HandleTable.windowUsed(), before - 1)
            HandleTable.resetWindow(-1)
            @Assert(HandleTable.getAny(a).isSome(), true)
            @Assert(HandleTable.genOf(a), gen) // ID/gen 不变
            @Assert(HandleTable.getAny(b).isNone(), true) // 未迁出的槽随窗口释放
            // 不参与重用：后续分配拿不到 a 的 idx
            let n1 = HandleTable.append(c, 'n1', TypeToken.STRING)
            let n2 = HandleTable.append(c, 'n2', TypeToken.STRING)
            @Assert(HandleTable.idxOf(n1) == HandleTable.idxOf(a), false)
            @Assert(HandleTable.idxOf(n2) == HandleTable.idxOf(a), false)
        } finally {
            JitContext.free(c)
        }
    }

    /** 槽级免级联：只迁出容器那 1 槽；元素（宿主原生引用）不产生新槽、窗口重置后仍可读。 */
    @TestCase
    public func moveOutGroupIsSlotLevel(): Unit {
        setup()
        let c = ctx()
        try {
            let list = ArrayList<Any>()
            list.add(Int64(7))
            list.add('elem')
            let cid = HandleTable.append(c, list, TypeToken.LIST)
            let before = HandleTable.windowUsed()
            HandleTable.moveOutGroup([cid])
            @Assert(HandleTable.windowUsed(), before - 1)
            HandleTable.resetWindow(-1)
            let back = HandleTable.fetchList(cid)
            @Assert(back.size, 2)
            match (back[0]) {
                case n: Int64 => @Assert(n, 7)
                case _ => @Assert(1, 2)
            }
            match (back[1]) {
                case s: String => @Assert(s, 'elem')
                case _ => @Assert(1, 2)
            }
            @Assert(HandleTable.liveCount(), 1) // 只提升容器 1 槽，无级联槽
        } finally {
            JitContext.free(c)
        }
    }
}
