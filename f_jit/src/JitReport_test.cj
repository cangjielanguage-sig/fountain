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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.InterruptedException
import fountain::f_jit.base.JitException
import fountain::f_jit.runtime.JitContext

/** S6.4：三态收尾与异常转换（§8.2.3）。 */
@Test
public class JitReport_test {
    @TestCase
    public func okReturnsValueWithoutReplay(): Unit {
        let ctx = JitReport_test.ctx()
        let calls = ArrayList<Bool>()
        let r = JitReport.finish(ctx, 42, { =>
            calls.add(true)
            0
        }, '')
        @Assert(r, 42)
        @Assert(calls.isEmpty(), true)
        JitContext.free(ctx)
    }

    @TestCase
    public func deoptReplaysTransparently(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.DEOPT
        let calls = ArrayList<Bool>()
        let r = JitReport.finish(ctx, -1, { =>
            calls.add(true)
            7
        }, '')
        @Assert(r, 7)
        @Assert(calls.size, 1)
        JitContext.free(ctx)
    }

    @TestCase
    public func interruptThrowsInterruptedException(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.INTERRUPT
        try {
            let _ = JitReport.finish(ctx, -1, { => 0 }, '')
            @Fail('未抛 InterruptedException')
        } catch (e: InterruptedException) {
            @Assert(e.message.contains('中断'), true)
        }
        JitContext.free(ctx)
    }

    @TestCase
    public func errorCarriesOriginalCodeAndSite(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = 3
        ctx.site = 42
        ctx.fnId = 7
        try {
            let _ = JitReport.finish(ctx, -1, { => 0 }, 'INT64 溢出')
            @Fail('未抛 JitException')
        } catch (e: JitException) {
            @Assert(e.code, 3)
            @Assert(e.site, 42)
            @Assert(e.fnId, 7)
            @Assert(e.message, 'INT64 溢出')
            @Assert(e.sourcePos.isNone(), true)
        }
        JitContext.free(ctx)
    }

    @TestCase
    public func replayFailureBecomes99(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.DEOPT
        try {
            let _ = JitReport.finish(ctx, -1, { =>
                throw Exception('重跑炸了')
            }, '')
            @Fail('未抛 JitException(99)')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.HELPER_PANIC)
            @Assert(e.site, -1)
            @Assert(e.cause.isSome(), true)
        }
        JitContext.free(ctx)
    }

    @TestCase
    public func contractErrorSiteIsMinusOne(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.CALL_CONTRACT
        ctx.site = -1
        try {
            JitReport.throwJit(ctx, '契约错误')
            @Fail('未抛')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
            @Assert(e.site, -1)
        }
        JitContext.free(ctx)
    }

    /**
     * 桥的错误码映射覆盖全量正值域（m3 §2「映射范围」）：1–23 与 99 逐码按**原码**抛出，
     * 22（`ANY_CAST`）独立成行、不被折叠为 7 或 21。
     */
    @TestCase
    public func fullPositiveCodeRangeMapsToJitException(): Unit {
        var code: Int64 = 1
        var hit = 0
        while (code <= 23) {
            let c = JitReport_test.ctx()
            c.errCode = code
            c.site = code
            try {
                let _ = JitReport.finish(c, -1, { => 0 }, '')
                @Fail('未抛 JitException: ${code}')
            } catch (e: JitException) {
                @Assert(e.code, code)
                @Assert(e.site, code)
                hit = hit + 1
            }
            JitContext.free(c)
            code = code + 1
        }
        let c99 = JitReport_test.ctx()
        c99.errCode = ErrCode.HELPER_PANIC
        try {
            let _ = JitReport.finish(c99, -1, { => 0 }, '')
            @Fail('未抛 99')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.HELPER_PANIC)
            hit = hit + 1
        }
        JitContext.free(c99)
        @Assert(hit, 24)
    }

    /**
     * A1.3（P0-4）：DEOPT 重放前必须复位错误槽。
     *
     * 重放复用同一个 ctx；若进入时 `errCode` 仍是 −1，解释器会把它当「已失败」在第一条
     * 指令后中止。这里直接断言重放入口看到 0，且收尾后仍为 0。
     */
    @TestCase
    public func p0_4_replayResetsErrorSlot(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.DEOPT
        let seen = ArrayList<Int64>()
        let r = JitReport.finish(ctx, -1, { =>
            seen.add(ctx.errCode)
            42
        }, '')
        @Assert(seen.size, 1)
        @Assert(seen[0], 0)
        @Assert(r, 42)
        @Assert(ctx.errCode, 0)
        JitContext.free(ctx)
    }

    /** A1.4（P0-5）：重放中途的业务错误必须按原码抛出，不能被当成返回值。 */
    @TestCase
    public func p0_5_replayErrorIsRethrown(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.DEOPT
        try {
            let _ = JitReport.finish(ctx, -1, { =>
                ctx.errCode = ErrCode.DIV_ZERO
                7
            }, '')
            @Fail('重放错误被吞成返回值')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.DIV_ZERO)
        }
        JitContext.free(ctx)
    }

    /** A1.4（P0-5）：重放期的 −2 必须转 `InterruptedException`。 */
    @TestCase
    public func p0_5_replayInterruptThrows(): Unit {
        let ctx = JitReport_test.ctx()
        ctx.errCode = ErrCode.DEOPT
        try {
            let _ = JitReport.finish(ctx, -1, { =>
                ctx.errCode = ErrCode.INTERRUPT
                0
            }, '')
            @Fail('重放中断未抛异常')
        } catch (e: InterruptedException) {
            @Assert(e.message.contains('中断'), true)
        }
        JitContext.free(ctx)
    }

    private static func ctx(): JitContext {
        JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
    }
}
