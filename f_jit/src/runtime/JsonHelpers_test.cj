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
import fountain::f_data.json.{JsonArray, JsonObject}
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType

/**
 * M3 R4.6–R4.9：H81 `json_get` / H82 `json_set` / H83 `json_new` 与 frozen 传播。
 */
@Test
public class JsonHelpers_test {

    private static func mkCtx(): JitContext {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
    }

    private static func call(ctx: JitContext, hid: Int64, args: Array<Int64>): Int64 {
        invokeHelper(ctx, hid, args)
    }

    /** H83 构造空对象：可变、可写入；H81 读回；H82 写后可见。 */
    @TestCase
    public func newObjectIsMutableAndReadable(): Unit {
        let ctx = JsonHelpers_test.mkCtx()
        let h = JsonHelpers_test.call(ctx, 83, [0])
        @Assert(ctx.errCode, 0)
        let k = HandleTable.pin('a')
        let _ = JsonHelpers_test.call(ctx, 82, [h, k, Int64(LocalType.I64), 7])
        @Assert(ctx.errCode, 0)
        let boxed = JsonHelpers_test.call(ctx, 81, [h, k, 0])
        @Assert(ctx.errCode, 0)
        let back = JsonHelpers_test.call(ctx, 80, [boxed, Int64(LocalType.I64), 0xFFFF])
        @Assert(back, 7)
        JitContext.free(ctx)
    }

    /** 数组：越界 4；对象缺键 5。 */
    @TestCase
    public func readFailuresAreCoded(): Unit {
        let ctx = JsonHelpers_test.mkCtx()
        let arr = JsonHelpers_test.call(ctx, 83, [1])
        let _ = JsonHelpers_test.call(ctx, 81, [arr, 3, 1])
        @Assert(ctx.errCode, ErrCode.IDX_OOB)
        ctx.errCode = 0
        let obj = JsonHelpers_test.call(ctx, 83, [0])
        let _ = JsonHelpers_test.call(ctx, 81, [obj, HandleTable.pin('missing'), 0])
        @Assert(ctx.errCode, ErrCode.KEY_MISSING)
        JitContext.free(ctx)
    }

    /** 写：对象 upsert 新键；数组只能写既有下标（越界 4）。 */
    @TestCase
    public func writeBoundsFollowContainerSemantics(): Unit {
        let ctx = JsonHelpers_test.mkCtx()
        let obj = JsonHelpers_test.call(ctx, 83, [0])
        let _ = JsonHelpers_test.call(ctx, 82, [obj, HandleTable.pin('n'), Int64(LocalType.I64), 1])
        @Assert(ctx.errCode, 0)
        let arr = JsonHelpers_test.call(ctx, 83, [1])
        let _ = JsonHelpers_test.call(ctx, 82, [arr, 0, Int64(LocalType.I64), 1])
        @Assert(ctx.errCode, ErrCode.IDX_OOB)
        JitContext.free(ctx)
    }

    /** frozen：常量句柄写入 → 20；读传播让子盒也 frozen。 */
    @TestCase
    public func frozenBlocksWritesAndPropagates(): Unit {
        let ctx = JsonHelpers_test.mkCtx()
        let h = JsonHelpers_test.call(ctx, 83, [0])
        let k = HandleTable.pin('a')
        let _ = JsonHelpers_test.call(ctx, 82, [h, k, Int64(LocalType.I64), 1])
        HandleTable.markFrozen(h)
        let _ = JsonHelpers_test.call(ctx, 82, [h, k, Int64(LocalType.I64), 2])
        @Assert(ctx.errCode, ErrCode.READONLY)
        ctx.errCode = 0
        let child = JsonHelpers_test.call(ctx, 81, [h, k, 0])
        @Assert(HandleTable.isFrozen(child), true)
        JitContext.free(ctx)
    }

    /** 读出的标量已出口解包：Int64 盒可直接 `as Int64`；JSON null 是单例节点盒。 */
    @TestCase
    public func scalarsAreUnwrappedAtExit(): Unit {
        let ctx = JsonHelpers_test.mkCtx()
        let obj = JsonHelpers_test.call(ctx, 83, [0])
        let _ = JsonHelpers_test.call(ctx, 82, [obj, HandleTable.pin('n'), Int64(LocalType.I64), 9])
        let boxed = JsonHelpers_test.call(ctx, 81, [obj, HandleTable.pin('n'), 0])
        @Assert(invokeHelper(ctx, 79, [boxed, Int64(LocalType.I64), 0xFFFF]), 1)
        JitContext.free(ctx)
    }
}
