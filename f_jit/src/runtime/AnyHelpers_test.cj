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
import std.collection.ArrayList
import std.collection.HashMap
import fountain::f_jit.base.ErrCode
import fountain::f_jit.bytecode.ConstMapKey
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken

/**
 * A2 类界夹具：`AsBase` ← `AsDerived`；`AsOther` 与两者无继承关系。
 *
 * 这些类**不注册**到任何类表：本文件验证的是 H79/H80 对 `aux` 指向的 `$as$<C>` 的
 * **委托契约**（真实注册类的类界一致性由根包 `AnyHostCast_test` 端到端覆盖）。
 */
public open class AsBase {
    public init() {}
}

public class AsDerived <: AsBase {
    public init() {
        super()
    }
}

public class AsOther {
    public init() {}
}

/**
 * M3 R4.1–R4.3：H78 `any_box` / H79 `any_is` / H80 `any_as`。
 *
 * 直接驱动 helper（不经前端），验证装箱往返、集合外回答、未命中 22、分配账目；
 * A2 追加 14 目标的类界委托（aux = `$as$<C>` 的 hid）与句柄 tag/窗口记账。
 */
@Test
public class AnyHelpers_test {

    /**
     * 集合外类型（闭包）经桥装箱后**只可持有转发**：`is` 恒 0、`as` 以 22 失败。
     *
     * 盒本身由桥侧 `marshalArg(ANY, …)` 建立（这里直接 `appendAnyBox` 复刻同一形态），
     * 证明「不可转集」不会因为进了盒就获得转型能力（m3 §2「集合外类型可持有转发」）。
     */
    @TestCase
    public func closureHeldInBoxIsNotConvertible(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let f: (Int64) -> Int64 = { x => x + 1 }
        let boxed = HandleTable.appendAnyBox(ctx, f)
        @Assert(ctx.errCode, 0)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 12, 0xFFFF]), 0)
        @Assert(ctx.errCode, 0)
        let _ = AnyHelpers_test.call(ctx, 80, [boxed, 12, 0xFFFF])
        @Assert(ctx.errCode, ErrCode.ANY_CAST)
        // 仍可原样取回并调用（持有转发不被破坏）
        match (HandleTable.fetchAnyBox(boxed)) {
            case g: (Int64) -> Int64 => @Assert(g(41), 42)
            case _ => @Fail('盒内容丢失')
        }
        JitContext.free(ctx)
    }

    private static func mkCtx(): JitContext {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
    }

    /** `$as$AsBase` / `$as$AsOther` 两个 user helper（slot 0/1 ⇒ hid 0x100/0x101）。 */
    private static let HID_BASE: Int64 = 0x100
    private static let HID_OTHER: Int64 = 0x101

    private static func pushAsHelpers(): Unit {
        UserHelperTable.resetForTest()
        let isBase: (Array<Any>) -> Any = { args =>
            match (args[0]) {
                case _: AsBase => true
                case _ => false
            }
        }
        let isOther: (Array<Any>) -> Any = { args =>
            match (args[0]) {
                case _: AsOther => true
                case _ => false
            }
        }
        UserHelperTable.push(0u16, [
            UserHelperEntry(params: [LocalType.HOST_OBJECT], ret: LocalType.BOOL, impl: isBase),
            UserHelperEntry(params: [LocalType.HOST_OBJECT], ret: LocalType.BOOL, impl: isOther)
        ])
    }

    private static func call(ctx: JitContext, hid: Int64, args: Array<Int64>): Int64 {
        invokeHelper(ctx, hid, args)
    }

    /** 值型装箱往返：Int64 拷贝、取回逐位相等；登记 1 槽。 */
    @TestCase
    public func boxAndUnboxInt64(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let boxed = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.I64), 42])
        @Assert(ctx.errCode, 0)
        // 槽表：哨兵 1 + 盒 1
        @Assert(HandleTable.slotCount(), 2)
        let back = AnyHelpers_test.call(ctx, 80, [boxed, Int64(LocalType.I64), 0xFFFF])
        @Assert(ctx.errCode, 0)
        @Assert(back, 42)
        JitContext.free(ctx)
    }

    /** 引用型装箱：同一对象引用（不是拷贝）。 */
    @TestCase
    public func boxKeepsReferenceIdentity(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let s = 'hello'
        let h = HandleTable.pin(s)
        let boxed = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.STRING), h])
        @Assert(ctx.errCode, 0)
        let back = AnyHelpers_test.call(ctx, 80, [boxed, Int64(LocalType.STRING), 0xFFFF])
        @Assert(ctx.errCode, 0)
        @Assert(HandleTable.fetchString(back), 'hello')
        JitContext.free(ctx)
    }

    /** `is`：命中 / 未命中 / 集合外（答 0，不置错误码）。 */
    @TestCase
    public func isAnswersWithoutFailing(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let boxed = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.I64), 7])
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, Int64(LocalType.I64), 0xFFFF]), 1)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, Int64(LocalType.STRING), 0xFFFF]), 0)
        // 集合外类型（Closure=12）恒假，且不是错误
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 12, 0xFFFF]), 0)
        @Assert(ctx.errCode, 0)
        JitContext.free(ctx)
    }

    /** `as` 未命中：错误码 22，不是 7/8。 */
    @TestCase
    public func asMismatchIsAnyCast(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let boxed = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.STRING), HandleTable.pin('x')])
        let _ = AnyHelpers_test.call(ctx, 80, [boxed, Int64(LocalType.I64), 0xFFFF])
        @Assert(ctx.errCode, ErrCode.ANY_CAST)
        JitContext.free(ctx)
    }

    /** 二次装箱与集合外类型装箱都被拒绝（8）。 */
    @TestCase
    public func boxRejectsNonConvertibleTypes(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let _ = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.ANY), 0])
        @Assert(ctx.errCode, ErrCode.HANDLE_TYPE)
        ctx.errCode = 0
        let _ = AnyHelpers_test.call(ctx, 78, [13, 0])
        @Assert(ctx.errCode, ErrCode.HANDLE_TYPE)
        JitContext.free(ctx)
    }

    /**
     * 容器的「不变语义」：`ArrayList<Any>` 命中。
     *
     * 边界：`ArrayList<Int64>` **当前无法 pin 进句柄表**（`tokenOf` 只认 `ArrayList<Any>`，
     * 其余返回 RESERVED → 19）——这是 M1 就有的容器类型外置约束，不是 M3 引入的；
     * 因此「元素类型一致」的 finite 分支表退化为「aux = 15/0xFFFF 命中、其余不命中」
     *（design D18）；元素码分派见 `containerAuxChecksElementType`。
     */
    /** 容器的「不变语义」：`ArrayList<Any>` 命中。 */
    @TestCase
    public func containerMatchIsInvariant(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let anys = ArrayList<Any>()
        anys.add(1)
        let boxA = AnyHelpers_test.call(ctx, 78,
            [Int64(LocalType.LIST), HandleTable.pin(anys)])
        @Assert(AnyHelpers_test.call(ctx, 79, [boxA, Int64(LocalType.LIST), 0xFFFF]), 1)
        JitContext.free(ctx)
    }

    /**
     * R4.4/R4.5：容器的 `aux` 分派——`List<Any>`（aux=15）与「未指定」（aux=0xFFFF）命中；
     * `List<Int64>`（aux=0）按**不变语义**不命中（`is` 答 0、`as` 置 22）。
     */
    @TestCase
    public func containerAuxChecksElementType(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let anys = ArrayList<Any>()
        anys.add(1)
        let boxA = AnyHelpers_test.call(ctx, 78,
            [Int64(LocalType.LIST), HandleTable.pin(anys)])
        @Assert(AnyHelpers_test.call(ctx, 79, [boxA, Int64(LocalType.LIST), 15]), 1)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxA, Int64(LocalType.LIST), 0xFFFF]), 1)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxA, Int64(LocalType.LIST), 0]), 0)
        @Assert(ctx.errCode, 0)
        // as：命中 → 句柄；不命中 → 22
        let hit = AnyHelpers_test.call(ctx, 80, [boxA, Int64(LocalType.LIST), 15])
        @Assert(ctx.errCode, 0)
        @Assert(hit != 0, true)
        let _ = AnyHelpers_test.call(ctx, 80, [boxA, Int64(LocalType.LIST), 0])
        @Assert(ctx.errCode, ErrCode.ANY_CAST)
        JitContext.free(ctx)
    }

    /** Map 的 `aux = (键码 << 8) | 值码`：值码 = 15 命中、值码 = 0 不命中。 */
    @TestCase
    public func mapAuxChecksValueType(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let m = HashMap<ConstMapKey, Any>()
        m.add(ConstMapKey('k', 's:k'), 1)
        let boxM = AnyHelpers_test.call(ctx, 78,
            [Int64(LocalType.MAP), HandleTable.pin(m)])
        // Map<String, Any> = (4<<8)|15 = 1039；Map<String, Int64> = 1024
        @Assert(AnyHelpers_test.call(ctx, 79, [boxM, Int64(LocalType.MAP), 1039]), 1)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxM, Int64(LocalType.MAP), 1024]), 0)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxM, Int64(LocalType.MAP), 0xFFFF]), 1)
        let _ = AnyHelpers_test.call(ctx, 80, [boxM, Int64(LocalType.MAP), 1024])
        @Assert(ctx.errCode, ErrCode.ANY_CAST)
        JitContext.free(ctx)
    }

    /**
     * 盒经容器往返（m3 §1「存储」能力面）：`MAKE_LIST` → `any_box` → `LIST_APPEND` → `GET_IDX`
     * → `any_as` 五步逐段断言，定位「盒存进容器就取不出来」的层次（runtime / 编译产物）。
     */
    @TestCase
    public func boxRoundTripsThroughList(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let list = AnyHelpers_test.call(ctx, 70, [])
        @Assert(ctx.errCode, 0)
        @Assert(list != 0, true)
        let boxed = AnyHelpers_test.call(ctx, 78, [Int64(LocalType.I64), 7])
        @Assert(ctx.errCode, 0)
        @Assert(boxed != 0, true)
        let _ = AnyHelpers_test.call(ctx, 43, [list, boxed])
        @Assert(ctx.errCode, 0)
        let cell = AnyHelpers_test.call(ctx, 2, [list, 0])
        @Assert(ctx.errCode, 0)
        @Assert(cell != 0, true)
        let back = AnyHelpers_test.call(ctx, 80, [cell, Int64(LocalType.I64), 0xFFFF])
        @Assert(ctx.errCode, 0)
        @Assert(back, 7)
        JitContext.free(ctx)
    }

    // ------------------------------------------------------------------
    // A2：14 目标的类界（P0-1）与句柄/窗口（P2-6）
    // ------------------------------------------------------------------

    /**
     * P0-1b：`as C` 命中后的句柄 **tag = 11（HOST_OBJECT）**，可原样取回同一对象；
     * 且本次命中在窗口内登记 1 槽。
     */
    @TestCase
    public func p0_1_asHostClassReturnsTag11(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        AnyHelpers_test.pushAsHelpers()
        let probe = AsDerived()
        let boxed = HandleTable.pinAnyBox(probe)
        let before = HandleTable.windowUsed()
        let out = AnyHelpers_test.call(ctx, 80, [boxed, 14, AnyHelpers_test.HID_BASE])
        @Assert(ctx.errCode, 0)
        @Assert(HandleTable.tagOf(out), TypeToken.HOST_OBJECT)
        @Assert(HandleTable.tagOf(out), 11u16)
        @Assert(HandleTable.windowUsed(), before + 1)
        @Assert(refEq(HandleTable.fetchHostObject(out), probe), true)
        match (HandleTable.getAs(out, TypeToken.HOST_OBJECT)) {
            case Some(o) =>
                match (o) {
                    case got: AsDerived => @Assert(refEq(got, probe), true)
                    case _ => @Fail('取回的不是原对象')
                }
            case None => @Fail('getAs(HOST_OBJECT) 取回失败')
        }
        JitContext.free(ctx)
    }

    /**
     * P0-1a：类界由 `aux` 指向的 `$as$<C>` 决定——命中 / 无关类不命中 / 兼容口径仍命中；
     * `is` 与 `as` 同一判定；hid 不存在 ⇒ 8（契约错误，不是 22）。
     */
    @TestCase
    public func p0_1_asHostClassRespectsClassBoundary(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        AnyHelpers_test.pushAsHelpers()
        let probe = AsDerived()
        let boxed = HandleTable.pinAnyBox(probe)
        // is：父类命中、无关类不命中、0xFFFF 兼容口径命中
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 14, AnyHelpers_test.HID_BASE]), 1)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 14, AnyHelpers_test.HID_OTHER]), 0)
        @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 14, 0xFFFF]), 1)
        @Assert(ctx.errCode, 0)
        // as：无关类 ⇒ 22；兼容口径 ⇒ 命中
        let _ = AnyHelpers_test.call(ctx, 80, [boxed, 14, AnyHelpers_test.HID_OTHER])
        @Assert(ctx.errCode, ErrCode.ANY_CAST)
        ctx.errCode = 0
        let compat = AnyHelpers_test.call(ctx, 80, [boxed, 14, 0xFFFF])
        @Assert(ctx.errCode, 0)
        @Assert(HandleTable.tagOf(compat), TypeToken.HOST_OBJECT)
        // 未知 hid ⇒ 8
        let _ = AnyHelpers_test.call(ctx, 79, [boxed, 14, 0x222])
        @Assert(ctx.errCode, ErrCode.HANDLE_TYPE)
        JitContext.free(ctx)
    }

    /**
     * P2-6：H80 的句柄型分支计入窗口——触顶第 N+1 次报 16；H79 零分配。
     *
     * 用 String 目标（每次 `as` 必然新登记 1 槽，不受 14 的同对象去重影响）；
     * `capacityLimit` 卡在「基线 + 2」以构造触顶。
     */
    @TestCase
    public func p2_6_anyAsCountsWindow(): Unit {
        HandleTable.resetForTest()
        let savedLimit = HandleTable.capacityLimit
        HandleTable.capacityLimit = 4
        let boxed = HandleTable.pinAnyBox('x') // 路径 B：idx 1，不占窗口
        HandleTable.openWindow(1)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(),
            hwCap: HandleTable.windowCapOf(), fnId: 1, dbgBase: 0)
        HandleTable.syncTo(ctx)
        try {
            @Assert(AnyHelpers_test.call(ctx, 80, [boxed, 4, 0xFFFF]) != 0, true)
            @Assert(ctx.errCode, 0)
            @Assert(AnyHelpers_test.call(ctx, 80, [boxed, 4, 0xFFFF]) != 0, true)
            @Assert(ctx.errCode, 0)
            @Assert(HandleTable.windowUsed(), 2)
            let _ = AnyHelpers_test.call(ctx, 80, [boxed, 4, 0xFFFF])
            @Assert(ctx.errCode, ErrCode.HANDLE_WINDOW_FULL)
            @Assert(HandleTable.windowUsed(), 2)
            // H79 纯读：1000 次不改变窗口与表长
            ctx.errCode = 0
            let slots = HandleTable.slotCount()
            var i = 0
            while (i < 1000) {
                @Assert(AnyHelpers_test.call(ctx, 79, [boxed, 4, 0xFFFF]), 1)
                i = i + 1
            }
            @Assert(ctx.errCode, 0)
            @Assert(HandleTable.slotCount(), slots)
            @Assert(HandleTable.windowUsed(), 2)
        } finally {
            HandleTable.capacityLimit = savedLimit
            JitContext.free(ctx)
        }
    }

    /** P2-1：`fetchAnyBox` 校验代数——释放 → 槽复用 → 旧 ID 必以 8 失败。 */
    @TestCase
    public func p2_1_fetchAnyBoxChecksGeneration(): Unit {
        let ctx = AnyHelpers_test.mkCtx()
        let boxed = HandleTable.appendAnyBox(ctx, Int64(7))
        let idx = HandleTable.idxOf(boxed)
        let gen = HandleTable.genOf(boxed)
        HandleTable.release(boxed)
        let reused = HandleTable.appendAnyBox(ctx, Int64(8))
        @Assert(HandleTable.idxOf(reused), idx)
        @Assert(HandleTable.genOf(reused) != gen, true)
        let _ = AnyHelpers_test.call(ctx, 79, [boxed, 0, 0xFFFF])
        @Assert(ctx.errCode, ErrCode.HANDLE_TYPE)
        ctx.errCode = 0
        // 新 ID 仍可读（校验只拦旧 ID，不误伤复用后的槽）
        @Assert(AnyHelpers_test.call(ctx, 79, [reused, 0, 0xFFFF]), 1)
        @Assert(ctx.errCode, 0)
        JitContext.free(ctx)
    }
}
