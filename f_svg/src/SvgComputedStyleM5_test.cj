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
public class SvgComputedStyleM5_test {
    private func styleOf(attributes: String): SvgComputedStyle {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"p\" " + attributes + ">" +
            "<rect id=\"r\"/></g></svg>"
        )
        m5StyleOf(tree, document.elementById("r"))
    }

    private func selfStyleOf(attributes: String): SvgComputedStyle {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
        )
        m5StyleOf(tree, document.elementById("r"))
    }

    private func parentStyleOf(attributes: String): (SvgComputedStyle, SvgComputedStyle) {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"p\" " + attributes + ">" +
            "<rect id=\"r\"/></g></svg>"
        )
        (
            m5StyleOf(tree, document.elementById("p")),
            m5StyleOf(tree, document.elementById("r"))
        )
    }

    /** 八个新属性的初始值。 */
    @TestCase
    public func initialValues(): Unit {
        let style = styleOf("")
        @Assert(style.get("paint-order") == Some("fill stroke markers"))
        @Assert(style.get("mix-blend-mode") == Some("normal"))
        @Assert(style.get("isolation") == Some("auto"))
        @Assert(style.get("transform-origin") == Some("0 0"))
        @Assert(style.get("transform-box") == Some("view-box"))
        @Assert(style.get("direction") == Some("ltr"))
        @Assert(style.get("unicode-bidi") == Some("normal"))
        @Assert(style.get("font-kerning") == Some("auto"))
    }

    /** 继承性：paint-order / direction / font-kerning 继承，其余不继承。 */
    @TestCase
    public func inheritance(): Unit {
        let (parent, child) = parentStyleOf(
            "paint-order=\"stroke fill\" mix-blend-mode=\"multiply\" isolation=\"isolate\" " +
            "direction=\"rtl\" font-kerning=\"none\""
        )
        @Assert(parent.get("paint-order") == Some("stroke fill markers"))
        @Assert(child.get("paint-order") == Some("stroke fill markers"))
        @Assert(parent.get("mix-blend-mode") == Some("multiply"))
        @Assert(child.get("mix-blend-mode") == Some("normal"))
        @Assert(parent.get("isolation") == Some("isolate"))
        @Assert(child.get("isolation") == Some("auto"))
        @Assert(child.get("direction") == Some("rtl"))
        @Assert(child.get("font-kerning") == Some("none"))
    }

    /** `inherit` / `initial` / `unset` 对继承与非继承属性分别生效。 */
    @TestCase
    public func cssWideKeywords(): Unit {
        let (_, inherited) = parentStyleOf("paint-order=\"stroke fill\"")
        @Assert(inherited.get("paint-order") == Some("stroke fill markers"))

        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g paint-order=\"stroke fill\">" +
            "<rect id=\"a\" style=\"paint-order: initial\"/>" +
            "<rect id=\"b\" style=\"paint-order: unset\"/>" +
            "<rect id=\"c\" mix-blend-mode=\"multiply\" style=\"mix-blend-mode: initial\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("a")).get("paint-order") == Some("fill stroke markers"))
        @Assert(m5StyleOf(tree, document.elementById("b")).get("paint-order") == Some("stroke fill markers"))
        @Assert(m5StyleOf(tree, document.elementById("c")).get("mix-blend-mode") == Some("normal"))
    }

    /** transform-origin 单值补 center，长度与百分比保留。 */
    @TestCase
    public func transformOriginNormalization(): Unit {
        @Assert(selfStyleOf("transform-origin=\"50%\"").get("transform-origin") == Some("50% center"))
        @Assert(selfStyleOf("transform-origin=\"10\"").get("transform-origin") == Some("10 center"))
        @Assert(selfStyleOf("transform-origin=\"left\"").get("transform-origin") == Some("left center"))
        @Assert(selfStyleOf("transform-origin=\"top\"").get("transform-origin") == Some("center top"))
        @Assert(selfStyleOf("transform-origin=\"10 20\"").get("transform-origin") == Some("10 20"))
        @Assert(selfStyleOf("transform-origin=\"right bottom\"").get("transform-origin") == Some("right bottom"))
    }

    /** 非法值回退初始值并追加 warning。 */
    @TestCase
    public func invalidValuesWarn(): Unit {
        let cases = [
            ("mix-blend-mode=\"plus-lighter\"", "mix-blend-mode", "normal", "mix-blend-mode"),
            ("isolation=\"maybe\"", "isolation", "auto", "isolation"),
            ("transform-origin=\"left middle\"", "transform-origin", "0 0", "transform-origin"),
            ("transform-box=\"content-box\"", "transform-box", "view-box", "transform-box"),
            ("direction=\"up\"", "direction", "ltr", "direction"),
            ("unicode-bidi=\"plaintext\"", "unicode-bidi", "normal", "unicode-bidi"),
            ("font-kerning=\"always\"", "font-kerning", "auto", "font-kerning")
        ]
        for ((attributes, property, expected, keyword) in cases) {
            let document = SvgParser.parse(
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
            )
            let resolver = SvgStyleResolver()
            let tree = resolver.compute(document.root)
            let style = m5StyleOf(tree, document.elementById("r"))
            @Assert(style.get(property) == Some(expected))
            var sawKeyword = false
            for (warning in resolver.warnings) {
                if (warning.contains(keyword)) {
                    sawKeyword = true
                }
            }
            @Assert(sawKeyword)
        }
    }

    /** paint-order 去重与缺项补齐在 M5 阶段按规范化字符串检查。 */
    @TestCase
    public func paintOrderNormalization(): Unit {
        @Assert(selfStyleOf("paint-order=\"stroke\"").get("paint-order") == Some("stroke fill markers"))
        @Assert(selfStyleOf("paint-order=\"markers fill\"").get("paint-order") == Some("markers fill stroke"))
    }
}
