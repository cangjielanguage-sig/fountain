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
public class SvgGradient_test {
    /** 线性渐变的几何属性与公共属性。 */
    @TestCase
    public func linearGradient(): Unit {
        let gradient = SvgLinearGradient(
            x1: SvgLength(0.0),
            y1: SvgLength(0.0),
            x2: SvgLength(100.0),
            y2: SvgLength(50.0)
        )
        @Assert(gradient.tag == "linearGradient")
        @Assert(gradient.x1 == Some(SvgLength(0.0)))
        @Assert(gradient.y2 == Some(SvgLength(50.0)))
        @Assert(gradient.attr("x2") == Some("100"))

        gradient.gradientUnits = SvgCoordinateUnits.ObjectBoundingBox
        @Assert(gradient.attr("gradientUnits") == Some("objectBoundingBox"))
        @Assert(gradient.gradientUnits == Some(SvgCoordinateUnits.ObjectBoundingBox))

        gradient.gradientTransform = SvgTransform.parse("rotate(45)")
        @Assert(gradient.attr("gradientTransform") == Some("rotate(45)"))
        @Assert(gradient.gradientTransform == Some(SvgTransform.parse("rotate(45)")))

        gradient.spreadMethod = SvgSpreadMethod.Reflect
        @Assert(gradient.attr("spreadMethod") == Some("reflect"))
        @Assert(gradient.spreadMethod == Some(SvgSpreadMethod.Reflect))

        gradient.href = "#base"
        @Assert(gradient.attr(SvgNamespaces.XLINK, "href") == Some("#base"))
        @Assert(gradient.href == Some("#base"))
    }

    /** 径向渐变的几何属性。 */
    @TestCase
    public func radialGradient(): Unit {
        let gradient = SvgRadialGradient(
            cx: SvgLength(50.0, unit: SvgLengthUnit.Percent),
            cy: SvgLength(50.0, unit: SvgLengthUnit.Percent),
            r: SvgLength(50.0, unit: SvgLengthUnit.Percent),
            fx: SvgLength(25.0, unit: SvgLengthUnit.Percent),
            fy: SvgLength(75.0, unit: SvgLengthUnit.Percent)
        )
        @Assert(gradient.tag == "radialGradient")
        @Assert(gradient.cx == Some(SvgLength(50.0, unit: SvgLengthUnit.Percent)))
        @Assert(gradient.cy == Some(SvgLength(50.0, unit: SvgLengthUnit.Percent)))
        @Assert(gradient.r == Some(SvgLength(50.0, unit: SvgLengthUnit.Percent)))
        @Assert(gradient.fx == Some(SvgLength(25.0, unit: SvgLengthUnit.Percent)))
        @Assert(gradient.fy == Some(SvgLength(75.0, unit: SvgLengthUnit.Percent)))
        gradient.cx = None
        @Assert(gradient.cx.isNone())
    }

    /** 缺省与非法枚举值。 */
    @TestCase
    public func defaultsAndInvalid(): Unit {
        let gradient = SvgLinearGradient()
        @Assert(gradient.gradientUnits.isNone())
        @Assert(gradient.gradientTransform.isNone())
        @Assert(gradient.spreadMethod.isNone())
        @Assert(gradient.href.isNone())
        @Assert(gradient.x1.isNone())

        gradient.setAttr("gradientUnits", "bogus")
        @Assert(gradient.gradientUnits.isNone())
        gradient.setAttr("spreadMethod", "bogus")
        @Assert(gradient.spreadMethod.isNone())
        gradient.setAttr("gradientTransform", "bogus(1)")
        @Assert(gradient.gradientTransform.isNone())

        @Assert(SvgCoordinateUnits.UserSpaceOnUse.toString() == "UserSpaceOnUse")
        @Assert(SvgSpreadMethod.Repeat.toString() == "Repeat")
    }
}

@Test
public class SvgStop_test {
    /** offset 百分比与小数归一。 */
    @TestCase
    public func offsetNormalization(): Unit {
        let stop = SvgStop()
        stop.setAttr("offset", "50%")
        @Assert(stop.offset == Some(0.5))
        stop.setAttr("offset", "0.25")
        @Assert(stop.offset == Some(0.25))
        stop.setAttr("offset", "0")
        @Assert(stop.offset == Some(0.0))
    }

    /** 越界钳制。 */
    @TestCase
    public func offsetClamping(): Unit {
        let stop = SvgStop()
        stop.setAttr("offset", "1.5")
        @Assert(stop.offset == Some(1.0))
        stop.setAttr("offset", "-0.2")
        @Assert(stop.offset == Some(0.0))
        stop.setAttr("offset", "150%")
        @Assert(stop.offset == Some(1.0))
        stop.setAttr("offset", "bogus")
        @Assert(stop.offset.isNone())

        stop.offset = 2.0
        @Assert(stop.offset == Some(1.0))
        @Assert(stop.attr("offset") == Some("1"))
    }

    /** stop-color 与 currentColor 的保留方式。 */
    @TestCase
    public func stopColor(): Unit {
        let stop = SvgStop()
        stop.stopColor = SvgColor.fromRgb(255, 0, 0)
        @Assert(stop.attr("stop-color") == Some("#ff0000"))
        @Assert(stop.stopColor == Some(SvgColor.fromRgb(255, 0, 0)))

        stop.setAttr("stop-color", "currentColor")
        @Assert(stop.stopColor.isNone())
        @Assert(stop.attr("stop-color") == Some("currentColor"))

        stop.setAttr("stop-color", "bogus")
        @Assert(stop.stopColor.isNone())
    }

    /** stop-opacity。 */
    @TestCase
    public func stopOpacity(): Unit {
        let stop = SvgStop()
        stop.stopOpacity = 0.5
        @Assert(stop.attr("stop-opacity") == Some("0.5"))
        @Assert(stop.stopOpacity == Some(0.5))
        stop.stopOpacity = None
        @Assert(stop.stopOpacity.isNone())
    }
}
