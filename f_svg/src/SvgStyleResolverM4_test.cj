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

private let m4NoParent: ?SvgComputedStyle = None

@Test
public class SvgStyleResolverM4_test {
    /** clip 函数归一与非法值降级。 */
    @TestCase
    public func clipNormalization(): Unit {
        let rect = SvgRect()
        rect.setAttr("style", "clip: rect(1px, 2px, 3px, 4px)")
        let resolver = SvgStyleResolver()
        let style = resolver.computeElement(rect, m4NoParent)
        let parsed = style.clipRect()
        @Assert(parsed.isSome())
        @Assert(parsed.getOrThrow().top == Some(1.0))
        @Assert(parsed.getOrThrow().right == Some(2.0))
        @Assert(parsed.getOrThrow().bottom == Some(3.0))
        @Assert(parsed.getOrThrow().left == Some(4.0))

        let auto = SvgRect()
        auto.setAttr("clip", "auto")
        @Assert(SvgStyleResolver().computeElement(auto, m4NoParent).get("clip") == Some("auto"))

        let invalid = SvgRect()
        invalid.setAttr("clip", "rect(1px 2px)")
        let invalidResolver = SvgStyleResolver()
        let invalidStyle = invalidResolver.computeElement(invalid, m4NoParent)
        @Assert(invalidStyle.get("clip") == Some("none"))
        @Assert(invalidResolver.warnings.size > 0)
        @Assert(invalidResolver.warnings[0].contains("clip"))
    }

    /** overflow: scroll / auto 归一为 hidden，非法值回退 hidden。 */
    @TestCase
    public func overflowNormalization(): Unit {
        for (raw in ["scroll", "auto"]) {
            let element = SvgRect()
            element.setAttr("overflow", raw)
            let style = SvgStyleResolver().computeElement(element, m4NoParent)
            @Assert(style.get("overflow") == Some("hidden"))
            @Assert(style.overflowMode() == SvgOverflow.Hidden)
        }
        let visible = SvgRect()
        visible.setAttr("overflow", "visible")
        @Assert(SvgStyleResolver().computeElement(visible, m4NoParent).get("overflow") == Some("visible"))

        let invalid = SvgRect()
        invalid.setAttr("overflow", "clip")
        let resolver = SvgStyleResolver()
        let style = resolver.computeElement(invalid, m4NoParent)
        @Assert(style.get("overflow") == Some("hidden"))
        @Assert(resolver.warnings.size > 0)
        @Assert(resolver.warnings[0].contains("overflow"))
    }

    /** baseline-shift 百分比相对 font-size 归一为像素。 */
    @TestCase
    public func baselineShiftNormalization(): Unit {
        let element = SvgRect()
        element.setAttr("font-size", "20")
        element.setAttr("baseline-shift", "10%")
        let style = SvgStyleResolver().computeElement(element, m4NoParent)
        @Assert(style.get("baseline-shift") == Some("2px"))
        @Assert(style.baselineShift() == SvgBaselineShift.Length(SvgLength(2.0, unit: SvgLengthUnit.Px)))

        element.setAttr("baseline-shift", "super")
        @Assert(SvgStyleResolver().computeElement(element, m4NoParent).get("baseline-shift") == Some("super"))

        element.setAttr("baseline-shift", "wat")
        let resolver = SvgStyleResolver()
        let invalid = resolver.computeElement(element, m4NoParent)
        @Assert(invalid.get("baseline-shift") == Some("baseline"))
        @Assert(resolver.warnings.size > 0)
    }

    /** text-decoration 去重并按规范顺序输出；none 与其它关键字同现按 none 并 warning。 */
    @TestCase
    public func textDecorationNormalization(): Unit {
        let element = SvgRect()
        element.setAttr("text-decoration", "line-through underline underline")
        @Assert(
            SvgStyleResolver().computeElement(element, m4NoParent).get("text-decoration") ==
                Some("underline line-through")
        )

        element.setAttr("text-decoration", "none underline")
        let resolver = SvgStyleResolver()
        let style = resolver.computeElement(element, m4NoParent)
        @Assert(style.get("text-decoration") == Some("none"))
        @Assert(resolver.warnings.size > 0)
        @Assert(resolver.warnings[0].contains("text-decoration"))
    }

    /** 非法的 M4 枚举回退到初始值并带属性名 warning。 */
    @TestCase
    public func invalidEnums(): Unit {
        let element = SvgRect()
        element.setAttr("dominant-baseline", "top")
        let resolver = SvgStyleResolver()
        let style = resolver.computeElement(element, m4NoParent)
        @Assert(style.get("dominant-baseline") == Some("auto"))
        @Assert(resolver.warnings.size > 0)
        @Assert(resolver.warnings[0].contains("dominant-baseline"))

        let vector = SvgRect()
        vector.setAttr("vector-effect", "scaling-stroke")
        let vectorResolver = SvgStyleResolver()
        @Assert(vectorResolver.computeElement(vector, m4NoParent).get("vector-effect") == Some("none"))
        @Assert(vectorResolver.warnings[0].contains("vector-effect"))

        let writing = SvgRect()
        writing.setAttr("writing-mode", "sideways")
        @Assert(SvgStyleResolver().computeElement(writing, m4NoParent).get("writing-mode") == Some("lr-tb"))
    }

    /** writing-mode 别名保留原值，语义由渲染层解释。 */
    @TestCase
    public func writingModeAliases(): Unit {
        let lr = SvgRect()
        lr.setAttr("writing-mode", "lr")
        @Assert(SvgStyleResolver().computeElement(lr, m4NoParent).get("writing-mode") == Some("lr"))
        let tb = SvgRect()
        tb.setAttr("writing-mode", "tb")
        @Assert(SvgStyleResolver().computeElement(tb, m4NoParent).get("writing-mode") == Some("tb"))
    }
}
