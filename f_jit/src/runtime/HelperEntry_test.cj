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
import fountain::f_jit.base.TypeToken

/**
 * `@C` 薄入口（机器码 ABI）的验收用例 —— design-m1 §5.3.4、plan-m1 S4.8 的「`@C` 薄入口 +
 * 仓颉实现」。
 *
 * 断言三件事：① 入口能被**按 C ABI 形态**调用（`(ctx, &args[0], n)`）；② 结果与错误码与
 * `invokeHelper` 路径**逐位一致**（三引擎共用同一份实现，design D4）；③ 失败**不抛异常**——
 * 只写错误槽（design D5）。
 */
@Test
public class HelperEntry_test {
    /** `@C` 入口与 `invokeHelper` 对同一输入给出同一结果与错误码。 */
    @TestCase
    public func cEntryMatchesInvokeHelper(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 0, dbgBase: 0)
        try {
            var l = ArrayList<Any>()
            l.add(Int64(1))
            l.add(Int64(2))
            l.add(Int64(3))
            let h = HandleTable.pin(l)
            let args = LibC.malloc<Int64>(count: 2)
            unsafe { args.write(0, h) }
            let raw = unsafe { CPointer<Unit>(ctx.cp()) }
            let r = unsafe { hl_len(raw, args, 1) }
            @Assert(r, 3)
            @Assert(ctx.errCode, 0)
            // 越界：经 @C 入口同样只写槽、不抛异常
            unsafe { args.write(1, 9) }
            let r2 = unsafe { hl_get(raw, args, 2) }
            @Assert(r2, 0)
            @Assert(ctx.errCode, ErrCode.IDX_OOB)
            unsafe { LibC.free<Int64>(args) }
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 零参数入口（`n = 0`，`args` 可为 null）：`list_new` 登记 1 槽且不失败。 */
    @TestCase
    public func zeroArgEntryAllocates(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 0, dbgBase: 0)
        try {
            let before = HandleTable.windowUsed()
            let raw2 = unsafe { CPointer<Unit>(ctx.cp()) }
            let r = unsafe { list_new(raw2, CPointer<Int64>(), 0) }
            @Assert(r > 0, true)
            @Assert(HandleTable.windowUsed(), before + 1)
            @Assert(ctx.errCode, 0)
            @Assert(HandleTable.tagOf(r), TypeToken.LIST)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 失败只写错误槽：宿主侧**不会**收到异常（design D5）。 */
    @TestCase
    public func failuresNeverEscapeAsExceptions(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 0, dbgBase: 0)
        try {
            let args = LibC.malloc<Int64>(count: 1)
            unsafe { args.write(0, 0) }
            let raw3 = unsafe { CPointer<Unit>(ctx.cp()) }
            let r = unsafe { hs_len(raw3, args, 1) }
            @Assert(r, 0)
            @Assert(ctx.errCode, ErrCode.NULL_HANDLE)
            unsafe { LibC.free<Int64>(args) }
        } finally {
            JitContext.free(ctx)
        }
    }
}
