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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

internal func expectSvgException(action: () -> Unit): SvgException {
    try {
        action()
    } catch (error: SvgException) {
        return error
    }
    throw Exception("期望抛出 SvgException，实际没有抛出")
}

@Test
public class SvgNumber_test {
    /** 整数不带小数点。 */
    @TestCase
    public func integers(): Unit {
        @Assert(formatSvgNumber(3.0) == "3")
        @Assert(formatSvgNumber(-3.0) == "-3")
        @Assert(formatSvgNumber(0.0) == "0")
        @Assert(formatSvgNumber(-0.0) == "0")
        @Assert(formatSvgNumber(123456789012345.0) == "123456789012345")
    }

    /** 小数去掉末尾 0，最多 6 位。 */
    @TestCase
    public func decimals(): Unit {
        @Assert(formatSvgNumber(1.5) == "1.5")
        @Assert(formatSvgNumber(-2.25) == "-2.25")
        @Assert(formatSvgNumber(1.500000) == "1.5")
        @Assert(formatSvgNumber(1.23456789) == "1.234568")
        @Assert(formatSvgNumber(0.0000012) == "0.000001")
    }

    /** 极小值归零，避免 1e-9 噪声。 */
    @TestCase
    public func tinyValuesBecomeZero(): Unit {
        @Assert(formatSvgNumber(1e-9) == "0")
        @Assert(formatSvgNumber(-1e-9) == "0")
        @Assert(formatSvgNumber(1e-7) == "0")
        @Assert(formatSvgNumber(1e-6) == "0.000001")
    }

    /** 不使用科学计数法。 */
    @TestCase
    public func noScientificNotation(): Unit {
        @Assert(formatSvgNumber(1e20) == "100000000000000000000")
        @Assert(formatSvgNumber(1e-5) == "0.00001")
    }

    /** 非有限值抛 InvalidValue。 */
    @TestCase
    public func nonFiniteRejected(): Unit {
        let nanError = expectSvgException({=> formatSvgNumber(Float64.NaN)})
        @Assert(nanError.kind == SvgErrorKind.InvalidValue)
        let infError = expectSvgException({=> formatSvgNumber(Float64.Inf)})
        @Assert(infError.kind == SvgErrorKind.InvalidValue)
        let negInfError = expectSvgException({=> formatSvgNumber(-Float64.Inf)})
        @Assert(negInfError.kind == SvgErrorKind.InvalidValue)
    }
}
