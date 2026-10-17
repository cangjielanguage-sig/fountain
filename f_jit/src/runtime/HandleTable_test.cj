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
import std.math.numeric.Decimal
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken

/**
 * S4.2–S4.5 句柄表（ID 形态 / 窗口 / 逃逸）的验收用例。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §1（槽 = `idx:u32 + tag:u16 + gen:u16`）、§8.1（四条路径）、
 * §9 附则 6（倍增扩容与 `capacityLimit` 封顶）、§9 附则 14（冻结决策 ④）。
 */
@Test
public class HandleTable_test {
    private func fresh(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
    }

    private func ctxOf(): JitContext {
        JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
    }

    /** 槽位三元组编码：`idx` 低 32 位、`tag` 次 16 位、`gen` 高 16 位；`idx=0` 留给 null。 */
    @TestCase
    public func idEncodesIdxTagGen(): Unit {
        let id = HandleTable.makeId(5, TypeToken.STRING, 3u16)
        @Assert(HandleTable.idxOf(id), 5)
        @Assert(HandleTable.tagOf(id), TypeToken.STRING)
        @Assert(HandleTable.genOf(id), 3u16)
        @Assert(HandleTable.makeId(0, 0u16, 0u16), 0)
        // gen ≥ 1 ⇒ ID ≥ 2^48，与普通整数值域不交
        let live = HandleTable.makeId(1, TypeToken.STRING, 1u16)
        @Assert(live >= 281474976710656, true)
    }

    /** 同对象复用同 ID；两个不同类型对象给出不同 ID（S4.2）。 */
    @TestCase
    public func pinReusesIdForSameObject(): Unit {
        fresh()
        let a = HandleTable.pin('hello')
        let b = HandleTable.pin('hello')
        @Assert(a, b)
        @Assert(HandleTable.tagOf(a), TypeToken.STRING)
        let d1 = HandleTable.pin(Decimal.parse('1.25'))
        let d2 = HandleTable.pin(Decimal.parse('2.50'))
        @Assert(d1 == a, false)
        @Assert(d1 == d2, false)
        @Assert(HandleTable.tagOf(d1), TypeToken.DECIMAL)
    }

    /** `get` 类型不符 ⇒ `None`（路径 D 读回的类型校验）。 */
    @TestCase
    public func getWithWrongTypeReturnsNone(): Unit {
        fresh()
        let s = HandleTable.pin('abc')
        @Assert(HandleTable.getAs(s, TypeToken.STRING).isSome(), true)
        @Assert(HandleTable.getAs(s, TypeToken.DECIMAL).isNone(), true)
        @Assert(HandleTable.getAny(0).isNone(), true)
    }

    /** `release` 后 `get` ⇒ `None`；即使槽位被复用，旧 ID 也因世代号不同被拦截。 */
    @TestCase
    public func releasedIdIsUnreachableAndGenBlocksReuse(): Unit {
        fresh()
        let ctx = ctxOf()
        try {
            HandleTable.openWindow(8)
            let s = HandleTable.pin('gone')
            @Assert(HandleTable.getAny(s).isSome(), true)
            let oldId = s
            HandleTable.release(s)
            @Assert(HandleTable.getAny(oldId).isNone(), true)
            // 同一对象重新 pin（不可变值按规范键去重 ⇒ 复用同一个槽位、但 gen 已 +1）
            let again = HandleTable.pin('gone')
            @Assert(HandleTable.idxOf(again), HandleTable.idxOf(oldId))
            @Assert(HandleTable.genOf(again) != HandleTable.genOf(oldId), true)
            @Assert(HandleTable.getAny(oldId).isNone(), true)
            @Assert(HandleTable.getAny(again).isSome(), true)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 无类型 token 的对象被拒绝（19；M2 起宿主类例外）。 */
    @TestCase
    public func pinRejectsObjectWithoutToken(): Unit {
        fresh()
        var code = 0
        try {
            let bad = HandleTable.pin(Int64(42))
            @Assert(bad, 0)
        } catch (e: HelperFail) {
            code = e.code
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
    }

    /** 窗口用满时**就地倍增**：扩容后容量 ≥ 2×已用数，不因容量失败（S4.3）。 */
    @TestCase
    public func windowDoublesWhenExhausted(): Unit {
        fresh()
        HandleTable.initialCapacity = 2
        let ctx = ctxOf()
        try {
            HandleTable.openWindow(2)
            @Assert(HandleTable.windowCapOf(), 2)
            var last = 0
            for (i in 0..40) {
                last = HandleTable.append(ctx, 'v${i}', TypeToken.STRING)
                @Assert(HandleTable.windowCapOf() >= 2 * HandleTable.windowUsed(), true)
            }
            @Assert(HandleTable.windowUsed(), 40)
            @Assert(HandleTable.tagOf(last), TypeToken.STRING)
            // ctx 镜像与表内记账一致
            @Assert(ctx.hwTop - ctx.hwBase, 40)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 触及全局上限 ⇒ 16，且错误站点指向触发点（S4.3）。 */
    @TestCase
    public func hittingCapacityLimitFailsWith16(): Unit {
        fresh()
        let ctx = ctxOf()
        try {
            HandleTable.openWindow(2)
            let base = HandleTable.windowBaseOf()
            HandleTable.capacityLimit = base + 3
            var code = 0
            var ok = 0
            for (i in 0..3) {
                let id = HandleTable.append(ctx, 'x${i}', TypeToken.STRING)
                @Assert(HandleTable.tagOf(id), TypeToken.STRING)
                ok = ok + 1
            }
            @Assert(ok, 3)
            ctx.site = 4242
            try {
                let id2 = HandleTable.append(ctx, 'boom', TypeToken.STRING)
                @Assert(id2, 0)
            } catch (e: HelperFail) {
                code = e.code
            }
            @Assert(code, ErrCode.HANDLE_WINDOW_FULL)
            @Assert(ctx.site, 4242)
        } finally {
            JitContext.free(ctx)
            HandleTable.capacityLimit = 1048576
        }
    }

    /** `initialCapacity` 在调用前可调、且不追溯进行中的调用（S4.3）。 */
    @TestCase
    public func initialCapacityAppliesToNextCallOnly(): Unit {
        fresh()
        HandleTable.initialCapacity = 4
        HandleTable.openWindow(4)
        @Assert(HandleTable.windowCapOf(), 4)
        // 进行中的调用不追溯
        HandleTable.initialCapacity = 64
        @Assert(HandleTable.windowCapOf(), 4)
        // 下一次调用生效
        HandleTable.openWindow(64)
        @Assert(HandleTable.windowCapOf(), 64)
    }

    /** `fetch` 三类坏标识：null → 6、tag 不符 → 8、坏 idx → 6（S4.4）。 */
    @TestCase
    public func fetchRejectsNullBadTagAndBadIndex(): Unit {
        fresh()
        let s = HandleTable.pin('abc')
        @Assert(codeOfFetch(0, TypeToken.STRING), ErrCode.NULL_HANDLE)
        @Assert(codeOfFetch(s, TypeToken.DECIMAL), ErrCode.HANDLE_TYPE)
        @Assert(codeOfFetch(HandleTable.makeId(999999, TypeToken.STRING, 1u16), TypeToken.STRING), ErrCode.NULL_HANDLE)
        @Assert(codeOfFetch(-1, TypeToken.STRING), ErrCode.NULL_HANDLE)
        // 世代号不符的陈旧 ID 同样走 6（不命中错配对象）
        HandleTable.release(s)
        @Assert(codeOfFetch(s, TypeToken.STRING), ErrCode.NULL_HANDLE)
    }

    private func codeOfFetch(id: Int64, tok: UInt16): Int64 {
        try {
            let v = HandleTable.fetchAny(id, tok)
            @Assert(HandleTable.tokenOf(v), tok)
            0
        } catch (e: HelperFail) {
            e.code
        }
    }

    /** `isType` 对 null 恒 false 且不失败；`tagOfHandle` 对 null → 6（H17 / H18 前置）。 */
    @TestCase
    public func isTypeAndTagOfHandle(): Unit {
        fresh()
        let s = HandleTable.pin('abc')
        @Assert(HandleTable.isType(s, TypeToken.STRING), true)
        @Assert(HandleTable.isType(s, TypeToken.LIST), false)
        @Assert(HandleTable.isType(0, TypeToken.STRING), false)
        @Assert(HandleTable.tagOfHandle(s), TypeToken.STRING)
        var code = 0
        try {
            let unused = HandleTable.tagOfHandle(0)
            @Assert(unused, 0u16)
        } catch (e: HelperFail) {
            code = e.code
        }
        @Assert(code, ErrCode.NULL_HANDLE)
    }

    /** 逃逸槽跨窗口重置**仍可取到同一对象且 ID 不变**；非逃逸槽随重置失效（S4.5）。 */
    @TestCase
    public func escapedSlotSurvivesWindowReset(): Unit {
        fresh()
        let ctx = ctxOf()
        try {
            HandleTable.openWindow(16)
            let esc = HandleTable.append(ctx, 'keep', TypeToken.STRING)
            let tmp = HandleTable.append(ctx, 'drop', TypeToken.STRING)
            HandleTable.escape(esc)
            HandleTable.resetWindow(-1)
            match (HandleTable.getAny(esc)) {
                case Some(v) => match (v) { case s: String => @Assert(s, 'keep'); case _ => @Assert(1, 2) }
                case None => @Assert('escaped slot lost', 'found')
            }
            @Assert(HandleTable.getAny(tmp).isNone(), true)
            @Assert(HandleTable.tagOf(esc), TypeToken.STRING)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 自动回收只作用于窗口区间内的槽：窗口之外的常驻槽不受重置影响。 */
    @TestCase
    public func resetOnlyReclaimsWindowRange(): Unit {
        fresh()
        let ctx = ctxOf()
        try {
            let outside = HandleTable.pin('outside')
            HandleTable.openWindow(8)
            let inside = HandleTable.append(ctx, 'inside', TypeToken.STRING)
            HandleTable.resetWindow(-1)
            @Assert(HandleTable.getAny(outside).isSome(), true)
            @Assert(HandleTable.getAny(inside).isNone(), true)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `gen+1` 后槽位可复用（新 ID 与原 ID 不同），活槽数不虚增。 */
    @TestCase
    public func releasedSlotIsReusableWithNewGen(): Unit {
        fresh()
        let a = HandleTable.pin('r1')
        let before = HandleTable.slotCount()
        HandleTable.release(a)
        @Assert(HandleTable.liveCount(), 0)
        let b = HandleTable.pin('r2')
        @Assert(HandleTable.slotCount(), before)
        @Assert(HandleTable.idxOf(b), HandleTable.idxOf(a))
        @Assert(HandleTable.genOf(b) != HandleTable.genOf(a), true)
        @Assert(HandleTable.liveCount(), 1)
    }

    /** 逃逸区登记：句柄被标记逃逸且快照可枚举（S4.5 `EscapeArea`）。 */
    @TestCase
    public func escapeAreaRegistersIds(): Unit {
        fresh()
        let area = EscapeArea()
        let a = HandleTable.pin('e1')
        let b = HandleTable.pin('e2')
        area.add(a)
        area.add(a)
        area.add(b)
        @Assert(area.size(), 2)
        @Assert(area.contains(a), true)
        @Assert(HandleTable.isEscaped(a), true)
        @Assert(HandleTable.isEscaped(b), true)
        area.clear()
        @Assert(area.size(), 0)
    }

    /** 常量槽（路径 A）被标记，且**不**随窗口重置失效。 */
    @TestCase
    public func constSlotIsMarkedAndPermanent(): Unit {
        fresh()
        let ctx = ctxOf()
        try {
            let c = HandleTable.pinConst('const')
            @Assert(HandleTable.isConst(c), true)
            HandleTable.openWindow(4)
            HandleTable.resetWindow(-1)
            @Assert(HandleTable.getAny(c).isSome(), true)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `cell` ↔ 宿主对象的互转：活句柄取对象，非句柄按原值装箱（§3.2 cell 表示）。 */
    @TestCase
    public func cellAndAnyConversion(): Unit {
        fresh()
        let s = HandleTable.pin('cv')
        @Assert(HandleTable.isLiveHandle(s), true)
        @Assert(HandleTable.isLiveHandle(0), false)
        @Assert(HandleTable.isLiveHandle(12345), false)
        match (HandleTable.cellToAny(s)) {
            case v: String => @Assert(v, 'cv')
            case _ => @Assert('bad', 'good')
        }
        @Assert(HandleTable.anyToCell(Int64(7)), 7)
        @Assert(HandleTable.anyToCell(true), 1)
        @Assert(HandleTable.anyToCell(false), 0)
        let f = Float64(1.5)
        @Assert(HandleTable.anyToCell(f), Int64(f.toBits()))
    }
}
