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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType

/**
 * M3 R4.1–R4.3：H78 `any_box` / H79 `any_is` / H80 `any_as`。
 *
 * 直接驱动 helper（不经前端），验证装箱往返、集合外回答、未命中 22、分配账目。
 */
@Test
public class AnyHelpers_test {

    private static func mkCtx(): JitContext {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
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
     * 元素码分派（`aux` 的有限分支表）属 R4.5 的 P2 工作，尚未落地。
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
}
