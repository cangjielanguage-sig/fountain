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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgComputedStyleM4_test {
    /** 8 个 M4 属性的初始值。 */
    @TestCase
    public func initialValues(): Unit {
        let rect = SvgRect()
        let style = styleOf(computeTree(rect), rect)
        @Assert(style.get("clip") == Some("none"))
        @Assert(style.get("overflow") == Some("hidden"))
        @Assert(style.get("vector-effect") == Some("none"))
        @Assert(style.get("dominant-baseline") == Some("auto"))
        @Assert(style.get("alignment-baseline") == Some("auto"))
        @Assert(style.get("baseline-shift") == Some("baseline"))
        @Assert(style.get("text-decoration") == Some("none"))
        @Assert(style.get("writing-mode") == Some("lr-tb"))
        @Assert(style.overflowMode() == SvgOverflow.Hidden)
        @Assert(style.vectorEffect() == SvgVectorEffect.NoEffect)
        @Assert(style.dominantBaseline() == SvgDominantBaseline.Auto)
        @Assert(style.alignmentBaseline() == SvgAlignmentBaseline.Auto)
        @Assert(style.baselineShift() == SvgBaselineShift.Baseline)
        @Assert(style.textDecoration().isNone())
        @Assert(style.writingMode() == SvgWritingMode.LrTb)
    }

    /** 可继承属性向子元素传递，不可继承属性保持初始值。 */
    @TestCase
    public func inheritance(): Unit {
        let group = SvgContainer(SvgContainerKind.Group)
        group.setAttr("writing-mode", "tb-rl")
        group.setAttr("dominant-baseline", "middle")
        group.setAttr("alignment-baseline", "central")
        group.setAttr("baseline-shift", "super")
        group.setAttr("clip", "auto")
        group.setAttr("overflow", "visible")
        group.setAttr("vector-effect", "non-scaling-stroke")
        group.setAttr("text-decoration", "underline")
        let text = SvgText()
        text.appendText("x")
        group.appendElement(text)
        let tree = computeTree(group)
        let child = styleOf(tree, text)
        @Assert(child.get("writing-mode") == Some("tb-rl"))
        @Assert(child.get("dominant-baseline") == Some("middle"))
        @Assert(child.get("alignment-baseline") == Some("central"))
        @Assert(child.get("baseline-shift") == Some("super"))
        @Assert(child.get("clip") == Some("none"))
        @Assert(child.get("overflow") == Some("hidden"))
        @Assert(child.get("vector-effect") == Some("none"))
        @Assert(child.get("text-decoration") == Some("none"))
    }

    /** inherit / initial / unset 对 M4 属性按既有规则生效。 */
    @TestCase
    public func cssWideKeywords(): Unit {
        let group = SvgContainer(SvgContainerKind.Group)
        group.setAttr("writing-mode", "tb-rl")
        group.setAttr("text-decoration", "underline")
        let text = SvgText()
        text.appendText("x")
        group.appendElement(text)
        text.setAttr("writing-mode", "unset")
        text.setAttr("text-decoration", "inherit")
        let inherited = styleOf(computeTree(group), text)
        @Assert(inherited.get("writing-mode") == Some("tb-rl"))
        @Assert(inherited.get("text-decoration") == Some("underline"))

        text.setAttr("writing-mode", "initial")
        text.setAttr("text-decoration", "initial")
        let initial = styleOf(computeTree(group), text)
        @Assert(initial.get("writing-mode") == Some("lr-tb"))
        @Assert(initial.get("text-decoration") == Some("none"))

        text.setAttr("writing-mode", "inherit")
        @Assert(styleOf(computeTree(group), text).get("writing-mode") == Some("tb-rl"))

        text.setAttr("overflow", "initial")
        @Assert(styleOf(computeTree(group), text).get("overflow") == Some("hidden"))
    }
}
