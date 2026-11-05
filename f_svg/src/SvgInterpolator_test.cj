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

@Test
public class SvgInterpolator_test {
    /** 数值 linear / discrete / spline。 */
    @TestCase
    public func numericModes(): Unit {
        @Assert(near(SvgInterpolator.numeric(0.0, 10.0, 0.25), 2.5))
        @Assert(near(SvgInterpolator.numeric(0.0, 10.0, 0.25, mode: SvgCalcMode.Discrete), 0.0))
        @Assert(near(SvgInterpolator.numeric(0.0, 10.0, 1.0, mode: SvgCalcMode.Discrete), 10.0))
        @Assert(near(SvgInterpolator.splineValue(0.5, 0.0, 0.0, 1.0, 1.0), 0.5))
        @Assert(near(SvgInterpolator.splineValue(0.0, 0.0, 0.0, 1.0, 1.0), 0.0))
        @Assert(near(SvgInterpolator.splineValue(1.0, 0.0, 0.0, 1.0, 1.0), 1.0))
    }

    /** 数值列表逐项插值，长度不等取较长者的多余项。 */
    @TestCase
    public func numericLists(): Unit {
        let same = SvgInterpolator.numericList([0.0, 10.0], [10.0, 20.0], 0.5)
        @Assert(near(same[0], 5.0) && near(same[1], 15.0))
        let mixed = SvgInterpolator.numericList([0.0], [10.0, 20.0], 0.5)
        @Assert(mixed.size == 2)
        @Assert(near(mixed[0], 5.0) && near(mixed[1], 20.0))
        let reversed = SvgInterpolator.numericList([10.0, 20.0], [0.0], 0.5)
        @Assert(reversed.size == 2)
        @Assert(near(reversed[0], 5.0) && near(reversed[1], 20.0))
    }

    /** 颜色插值与路径结构一致 / 不一致。 */
    @TestCase
    public func colorAndPath(): Unit {
        let mixed = SvgInterpolator.color(
            SvgColor.fromRgb(255, 0, 0),
            SvgColor.fromRgb(0, 0, 255),
            0.5
        )
        @Assert(mixed.red == 128 && mixed.blue == 128)
        let discrete = SvgInterpolator.color(
            SvgColor.fromRgb(255, 0, 0),
            SvgColor.fromRgb(0, 0, 255),
            0.5,
            mode: SvgCalcMode.Discrete
        )
        @Assert(discrete.red == 255)

        let first = SvgPathData.parse("M0 0 L10 0 L10 10 Z")
        let second = SvgPathData.parse("M10 10 L20 10 L20 20 Z")
        let interpolated = SvgInterpolator.path(first, second, 0.5) ?? SvgPathData(Array<SvgPathCommand>())
        @Assert(interpolated.commands.size == 4)
        @Assert(near(interpolated.commands[0].values[0], 5.0))
        @Assert(SvgInterpolator.path(first, SvgPathData.parse("M0 0 L5 5"), 0.5).isNone())

        @Assert(SvgInterpolator.stringValue("a", "b", 0.5) == "a")
        @Assert(SvgInterpolator.stringValue("a", "b", 1.0) == "b")
        @Assert(SvgInterpolator.stringValue("a", "b", 1.0, mode: SvgCalcMode.Discrete) == "a")
    }

    /** 变换逐参数插值。 */
    @TestCase
    public func transforms(): Unit {
        let from = SvgTransform.parse("translate(0 0) rotate(0) scale(1 1)")
        let to = SvgTransform.parse("translate(10 20) rotate(90) scale(2 3)")
        let middle = SvgInterpolator.transform(from, to, 0.5) ?? SvgTransform.identity
        @Assert(middle.operations.size == 3)
        match (middle.operations[0]) {
            case Translate(x, y) => @Assert(near(x, 5.0) && near(y, 10.0))
            case _ => @Fail("translate 插值失败")
        }
        match (middle.operations[1]) {
            case Rotate(angle, _, _) => @Assert(near(angle, 45.0))
            case _ => @Fail("rotate 插值失败")
        }
        match (middle.operations[2]) {
            case Scale(x, y) => @Assert(near(x, 1.5) && near(y, 2.0))
            case _ => @Fail("scale 插值失败")
        }
        @Assert(SvgInterpolator.transform(from, SvgTransform.parse("scale(2)"), 0.5).isNone())
    }
}
