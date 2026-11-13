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
import std.math.*

internal func near(actual: Float64, expected: Float64): Bool {
    abs(actual - expected) < 1e-9
}

@Test
public class SvgLengthContext_test {
    /** 默认上下文的基准：DPI 96、字号 16。 */
    @TestCase
    public func defaults(): Unit {
        let context = SvgLengthContext.of(200.0, 100.0)
        @Assert(context.viewportWidth == 200.0)
        @Assert(context.viewportHeight == 100.0)
        @Assert(context.fontSize == 16.0)
        @Assert(context.dpi == 96.0)
    }

    /** 绝对单位换算到用户单位。 */
    @TestCase
    public func absoluteUnits(): Unit {
        let context = SvgLengthContext.of(200.0, 100.0)
        @Assert(near(toUserUnits(SvgLength(1.0), SvgLengthAxis.Horizontal, context), 1.0))
        @Assert(near(toUserUnits(SvgLength(3.0, unit: SvgLengthUnit.Px), SvgLengthAxis.Horizontal, context), 3.0))
        @Assert(near(toUserUnits(SvgLength(1.0, unit: SvgLengthUnit.In), SvgLengthAxis.Horizontal, context), 96.0))
        @Assert(near(toUserUnits(SvgLength(2.54, unit: SvgLengthUnit.Cm), SvgLengthAxis.Horizontal, context), 96.0))
        @Assert(near(toUserUnits(SvgLength(25.4, unit: SvgLengthUnit.Mm), SvgLengthAxis.Horizontal, context), 96.0))
        @Assert(near(toUserUnits(SvgLength(72.0, unit: SvgLengthUnit.Pt), SvgLengthAxis.Horizontal, context), 96.0))
        @Assert(near(toUserUnits(SvgLength(1.0, unit: SvgLengthUnit.Pc), SvgLengthAxis.Horizontal, context), 16.0))
    }

    /** 字体相对单位以 fontSize 为基准。 */
    @TestCase
    public func fontRelativeUnits(): Unit {
        let context = SvgLengthContext(200.0, 100.0, fontSize: 20.0)
        @Assert(near(toUserUnits(SvgLength(1.5, unit: SvgLengthUnit.Em), SvgLengthAxis.Horizontal, context), 30.0))
        @Assert(near(toUserUnits(SvgLength(2.0, unit: SvgLengthUnit.Ex), SvgLengthAxis.Horizontal, context), 20.0))
        let small = SvgLengthContext(10.0, 10.0, fontSize: 12.0, dpi: 72.0)
        @Assert(near(toUserUnits(SvgLength(1.0, unit: SvgLengthUnit.In), SvgLengthAxis.Horizontal, small), 72.0))
    }

    /** 百分比按轴取基准：200×100 视口。 */
    @TestCase
    public func percentByAxis(): Unit {
        let context = SvgLengthContext.of(200.0, 100.0)
        @Assert(near(toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context), 100.0))
        @Assert(near(toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Vertical, context), 50.0))
        let diagonal = toUserUnits(
            SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Diagonal, context
        )
        @Assert(near(diagonal, sqrt(200.0 * 200.0 + 100.0 * 100.0) / sqrt(2.0) * 0.5))
    }

    /** 退化视口下百分比为 0，不抛错。 */
    @TestCase
    public func degenerateViewport(): Unit {
        let context = SvgLengthContext.of(0.0, 0.0)
        @Assert(near(toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context), 0.0))
        @Assert(near(toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Vertical, context), 0.0))
        @Assert(near(toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Diagonal, context), 0.0))
    }
}
