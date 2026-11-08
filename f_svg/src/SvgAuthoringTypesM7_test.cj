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
public class SvgAuthoringTypesM7_test {
    /** `SvgRestart` 的 SVG 拼写与相等语义。 */
    @TestCase
    public func restartSpelling(): Unit {
        @Assert(SvgRestart.Always.toString() == "always")
        @Assert(SvgRestart.WhenNotActive.toString() == "whenNotActive")
        @Assert(SvgRestart.Never.toString() == "never")
        @Assert(SvgRestart.Always == SvgRestart.Always)
        @Assert(SvgRestart.Always != SvgRestart.Never)
    }

    /** `SvgAnimationFill` 的 SVG 拼写与相等语义。 */
    @TestCase
    public func animationFillSpelling(): Unit {
        @Assert(SvgAnimationFill.Remove.toString() == "remove")
        @Assert(SvgAnimationFill.Freeze.toString() == "freeze")
        @Assert(SvgAnimationFill.Remove == SvgAnimationFill.Remove)
        @Assert(SvgAnimationFill.Remove != SvgAnimationFill.Freeze)
    }

    /** `SvgAnimationTransformType` 的 SVG 拼写与相等语义。 */
    @TestCase
    public func transformTypeSpelling(): Unit {
        @Assert(SvgAnimationTransformType.Translate.toString() == "translate")
        @Assert(SvgAnimationTransformType.Scale.toString() == "scale")
        @Assert(SvgAnimationTransformType.Rotate.toString() == "rotate")
        @Assert(SvgAnimationTransformType.SkewX.toString() == "skewX")
        @Assert(SvgAnimationTransformType.SkewY.toString() == "skewY")
        @Assert(SvgAnimationTransformType.Rotate == SvgAnimationTransformType.Rotate)
        @Assert(SvgAnimationTransformType.Rotate != SvgAnimationTransformType.Scale)
    }

    /** `SvgMotionRotate` 的三种形态与固定角度的无单位格式。 */
    @TestCase
    public func motionRotateSpelling(): Unit {
        @Assert(SvgMotionRotate.Auto.toString() == "auto")
        @Assert(SvgMotionRotate.AutoReverse.toString() == "auto-reverse")
        @Assert(SvgMotionRotate.Fixed(45.0).toString() == "45")
        @Assert(SvgMotionRotate.Fixed(-0.5).toString() == "-0.5")
        @Assert(SvgMotionRotate.Fixed(0.0).toString() == "0")
    }

    /** 带载荷的枚举相等性按载荷比较。 */
    @TestCase
    public func motionRotateEquality(): Unit {
        @Assert(SvgMotionRotate.Auto == SvgMotionRotate.Auto)
        @Assert(SvgMotionRotate.Auto != SvgMotionRotate.AutoReverse)
        @Assert(SvgMotionRotate.Fixed(45.0) == SvgMotionRotate.Fixed(45.0))
        @Assert(SvgMotionRotate.Fixed(45.0) != SvgMotionRotate.Fixed(46.0))
        @Assert(SvgMotionRotate.Fixed(45.0) != SvgMotionRotate.Auto)
    }
}
