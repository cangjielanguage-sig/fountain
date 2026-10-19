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

    private static func ctx(): JitContext {
        JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
    }
}
