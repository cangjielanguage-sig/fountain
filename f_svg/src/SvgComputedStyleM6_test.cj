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
public class SvgComputedStyleM6_test {
    private func selfStyleOf(attributes: String): (SvgComputedStyle, SvgStyleResolver) {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        (m5StyleOf(tree, document.elementById("r")), resolver)
    }

    private func childStyleOf(attributes: String): (SvgComputedStyle, SvgStyleResolver) {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"p\" " + attributes + ">" +
            "<rect id=\"r\"/></g></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        (m5StyleOf(tree, document.elementById("r")), resolver)
    }

    /** 初始值。 */
    @TestCase
    public func initialValues(): Unit {
        let (style, _) = selfStyleOf("")
        @Assert(style.pointerEvents() == SvgPointerEvents.Auto)
        @Assert(style.cursor() == "auto")
        @Assert(style.get("pointer-events") == Some("auto"))
        @Assert(style.get("cursor") == Some("auto"))
    }

    /** 两个属性都可继承。 */
    @TestCase
    public func inheritance(): Unit {
        let (style, _) = childStyleOf("pointer-events=\"none\" cursor=\"pointer\"")
        @Assert(style.pointerEvents() == SvgPointerEvents.None)
        @Assert(style.cursor() == "pointer")
    }

    /** `inherit` / `initial` / `unset` 语义。 */
    @TestCase
    public func keywords(): Unit {
        let (inheritStyle, _) = childStyleOf("pointer-events=\"none\" cursor=\"pointer\"")
        @Assert(inheritStyle.pointerEvents() == SvgPointerEvents.None)
        let (initialStyle, _) = selfStyleOf("pointer-events=\"initial\" cursor=\"initial\"")
        @Assert(initialStyle.pointerEvents() == SvgPointerEvents.Auto)
        @Assert(initialStyle.cursor() == "auto")
        let (unsetStyle, _) = childStyleOf("pointer-events=\"unset\" cursor=\"unset\"")
        @Assert(unsetStyle.pointerEvents() == SvgPointerEvents.Auto)
        @Assert(unsetStyle.cursor() == "auto")
    }

    /** 未知值回退并 warning。 */
    @TestCase
    public func invalidValuesWarn(): Unit {
        let (style, resolver) = selfStyleOf("pointer-events=\"bogus\" cursor=\"hand\"")
        @Assert(style.pointerEvents() == SvgPointerEvents.Auto)
        @Assert(style.cursor() == "auto")
        var pointerWarnings = 0
        var cursorWarnings = 0
        for (warning in resolver.warnings) {
            if (warning.contains("pointer-events")) {
                pointerWarnings++
            }
            if (warning.contains("cursor")) {
                cursorWarnings++
            }
        }
        @Assert(pointerWarnings == 1)
        @Assert(cursorWarnings == 1)
    }

    /** `url(...)` 回退 auto 并 warning（绕过解析期的外部引用过滤）。 */
    @TestCase
    public func cursorUrlWarns(): Unit {
        let rect = SvgRect()
        rect.setAttr("id", "r")
        let resolver = SvgStyleResolver(
            sheet: CssStyleSheet.parse("rect { cursor: url(cursor.cur), pointer }")
        )
        let style = resolver.computeElement(rect, Option<SvgComputedStyle>.None)
        @Assert(style.cursor() == "auto")
        var warnings = 0
        for (warning in resolver.warnings) {
            if (warning.contains("url")) {
                warnings++
            }
        }
        @Assert(warnings == 1)
    }

    /** 大小写归一为规范字符串。 */
    @TestCase
    public func caseNormalization(): Unit {
        let (style, _) = selfStyleOf("pointer-events=\"VISIBLEFILL\" cursor=\"POINTER\"")
        @Assert(style.pointerEvents() == SvgPointerEvents.VisibleFill)
        @Assert(style.get("pointer-events") == Some("visibleFill"))
        @Assert(style.cursor() == "pointer")
    }
}
