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
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.TCase

/** S6.5：`call<T>` 六步（§8.2）。 */
@Test
public class JitFunction_test {
    @TestCase
    public func returnsT(): Unit {
        let f = JitFunction_test.addFn()
        @Assert(TCase.hit('T15/call-returns-t', f.call<Int64>([20, 22]) == 42), true)
    }

    @TestCase
    public func argCountMismatch(): Unit {
        let f = JitFunction_test.addFn()
        @Assert(JitFunction_test.codeOf({ =>
            let _ = f.call<Int64>([1])
        }), ErrCode.CALL_CONTRACT)
    }

    @TestCase
    public func argTypeMismatch(): Unit {
        let f = JitFunction_test.addFn()
        @Assert(JitFunction_test.codeOf({ =>
            let _ = f.call<Int64>(['a', 2])
        }), ErrCode.CALL_CONTRACT)
    }

    @TestCase
    public func typeParamMismatch(): Unit {
        let f = JitFunction_test.addFn()
        @Assert(JitFunction_test.codeOf({ =>
            let _ = f.call<Float64>([1.0, 2.0])
        }),
            ErrCode.CALL_CONTRACT)
    }

    @TestCase
    public func deoptReplays(): Unit {
        let f = JitFunction(0, LocalType.I64, Array<UInt16>(),
            { ctx, _ =>
                ctx.errCode = ErrCode.DEOPT
                -1
            },
            { _, _ => 99 }, '')
        @Assert(f.call<Int64>(Array<Any>()), 99)
    }

    @TestCase
    public func contractErrorHasNoSite(): Unit {
        let f = JitFunction_test.addFn()
        try {
            let _ = f.call<Int64>([1])
            @Fail('未抛 19')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
            @Assert(e.site, -1)
            @Assert(e.sourcePos.isNone(), true)
        }
    }

    private static func addFn(): JitFunction {
        JitFunction(2, LocalType.I64, [LocalType.I64, LocalType.I64],
            { _, cells => cells[0] + cells[1] },
            { _, cells => cells[0] + cells[1] }, '')
    }

    private static func codeOf(body: () -> Unit): Int64 {
        try {
            body()
            -999
        } catch (e: JitException) {
            e.code
        }
    }
}

/** S6.10：卸载状态机（Ready → Unloading → Unloaded）。 */
@Test
public class JitFunctionLifecycle_test {
    @TestCase
    public func unloadThenCallIsRejected(): Unit {
        let f = JitFunctionLifecycle_test.fn()
        @Assert(f.call<Int64>(Array<Any>()), 1)
        @Assert(TCase.hit('T29/unload-succeeds', f.close(0)), true)
        @Assert(TCase.hit('T29/unloaded-visible', f.isClosed()), true)
        try {
            let _ = f.call<Int64>(Array<Any>())
            @Fail('未抛 19')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
            @Assert(e.site, -1)
        }
    }

    @TestCase
    public func doubleUnloadIsIdempotent(): Unit {
        let released = ArrayList<Int64>()
        let f = JitFunction(0, LocalType.I64, Array<UInt16>(),
            { _, _ => 1 }, { _, _ => 1 }, '',
            Some({ => released.add(1) }))
        @Assert(f.close(0), true)
        @Assert(f.close(0), true)
        @Assert(released.size, 1)
    }

    private static func fn(): JitFunction {
        JitFunction(0, LocalType.I64, Array<UInt16>(),
            { _, _ => 1 }, { _, _ => 1 }, '')
    }
}
