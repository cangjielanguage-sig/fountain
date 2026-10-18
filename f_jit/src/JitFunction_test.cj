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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType

/** S6.5：`call<T>` 六步（§8.2）。 */
@Test
public class JitFunction_test {
    @TestCase
    public func returnsT(): Unit {
        let f = JitFunction_test.addFn()
        @Assert(f.call<Int64>([20, 22]), 42)
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
