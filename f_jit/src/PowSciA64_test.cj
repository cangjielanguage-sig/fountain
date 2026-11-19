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

/**
 * 幂运算 `**` 与科学计数法在 **AArch64** 上的引擎级证据。
 *
 * `Pow_test` / `NumberLitSci_test` 只断言「值对不对」；而桥在 A64 降低失败时会**静默退回
 * 解释器**，那些用例仍然绿。这里用 `JitFunction.isJitBacked()` 把「必须由机器码执行」钉死
 * ——这也是本轮变更（`**` → `CALL_HELPER H84`、科学计数法在词法/常量层折叠）在 A64 上的
 * 唯一直接证据。
 *
 * 覆盖：正常幂、右结合、负指数（14）、溢出（3）、浮点科学计数法、前导点、十进制科学计数法。
 */
@Test
public class PowSciA64_test {

    private static func compiled(src: String): JitFunction {
        CompileCache.reset()
        Compiler().compile(src)
    }

    /** 正常幂与右结合：值正确，且单元必须由 A64 机器码承载。 */
    @TestCase
    public func powIsA64Backed(): Unit {
        let f = PowSciA64_test.compiled('{ => 2 ** 10 }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([]), 1024)

        let g = PowSciA64_test.compiled('{ => 2 ** 3 ** 2 }')
        @Assert(g.isJitBacked(), true)
        @Assert(g.call<Int64>([]), 512)
    }

    /** 错误路径（负指数 14 / 溢出 3）同样不得把单元踢回解释器。 */
    @TestCase
    public func powErrorsKeepA64Backing(): Unit {
        let neg = PowSciA64_test.compiled('{ => 2 ** -1 }')
        @Assert(neg.isJitBacked(), true)
        var negCode: Int64 = 0
        try {
            let _ = neg.call<Int64>([])
        } catch (e: JitException) {
            negCode = e.code
        }
        @Assert(negCode, ErrCode.ARG_MISMATCH)

        let ovf = PowSciA64_test.compiled('{ => 2 ** 63 }')
        @Assert(ovf.isJitBacked(), true)
        var ovfCode: Int64 = 0
        try {
            let _ = ovf.call<Int64>([])
        } catch (e: JitException) {
            ovfCode = e.code
        }
        @Assert(ovfCode, ErrCode.OVERFLOW_I64)
    }

    /** 浮点科学计数法（含前导点形态）在 A64 上仍是机器码直出常量。 */
    @TestCase
    public func floatSciNotationIsA64Backed(): Unit {
        let f = PowSciA64_test.compiled('{ => 1.5e3f64 }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Float64>([]), 1500.0)

        let g = PowSciA64_test.compiled('{ => .5e1f64 }')
        @Assert(g.isJitBacked(), true)
        @Assert(g.call<Float64>([]), 5.0)

        let h = PowSciA64_test.compiled('{ => 1.5e-2f64 }')
        @Assert(h.isJitBacked(), true)
        @Assert(h.call<Float64>([]), 0.015)
    }

    /** 十进制科学计数法（无后缀）同样必须 A64 承载。 */
    @TestCase
    public func decimalSciNotationIsA64Backed(): Unit {
        let f = PowSciA64_test.compiled('{ => Int64(2.5e3) }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([]), 2500)
    }
}
