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

internal func m5AttrSelectorMatches(selector: String, element: SvgElement): Bool {
    CssSelector.parse(selector).matches(element)
}

internal func m5RectWith(pairs: Array<(String, String)>): SvgElement {
    let element = SvgRect()
    for ((name, value) in pairs) {
        element.setAttr(name, value)
    }
    element
}

@Test
public class CssSelectorAttributeM5_test {
    /** 存在、等值、整词三种基本形式。 */
    @TestCase
    public func existenceAndEquality(): Unit {
        let element = m5RectWith([("fill", "red"), ("data-x", "a b")])
        @Assert(m5AttrSelectorMatches("[fill]", element))
        @Assert(m5AttrSelectorMatches("[fill=red]", element))
        @Assert(!m5AttrSelectorMatches("[fill=blue]", element))
        @Assert(m5AttrSelectorMatches("[data-x~=a]", element))
        @Assert(m5AttrSelectorMatches("[data-x~=b]", element))
        @Assert(!m5AttrSelectorMatches("[data-x~=ab]", element))
        @Assert(!m5AttrSelectorMatches("[missing]", element))
        @Assert(!m5AttrSelectorMatches("[missing=red]", element))
        @Assert(!m5AttrSelectorMatches("[missing~=red]", element))
    }

    /** 前缀、后缀、子串。 */
    @TestCase
    public func prefixSuffixSubstring(): Unit {
        let element = m5RectWith([("data-code", "zh-CN-01")])
        @Assert(m5AttrSelectorMatches("[data-code^=zh]", element))
        @Assert(!m5AttrSelectorMatches("[data-code^=CN]", element))
        @Assert(m5AttrSelectorMatches("[data-code$=01]", element))
        @Assert(!m5AttrSelectorMatches("[data-code$=CN]", element))
        @Assert(m5AttrSelectorMatches("[data-code*=CN]", element))
        @Assert(!m5AttrSelectorMatches("[data-code*=zz]", element))
    }

    /** 连字符匹配：等于或以「值 + -」开头。 */
    @TestCase
    public func dashMatch(): Unit {
        let element = m5RectWith([("lang", "zh-CN")])
        @Assert(m5AttrSelectorMatches("[lang|=zh]", element))
        @Assert(m5AttrSelectorMatches("[lang|=zh-CN]", element))
        @Assert(!m5AttrSelectorMatches("[lang|=z]", element))
        @Assert(!m5AttrSelectorMatches("[lang|=C]", element))
    }

    /** `i` 标志只影响 ASCII 大小写。 */
    @TestCase
    public func caseInsensitiveFlag(): Unit {
        let element = m5RectWith([("data-x", "Red")])
        @Assert(!m5AttrSelectorMatches("[data-x=red]", element))
        @Assert(m5AttrSelectorMatches("[data-x=red i]", element))
        @Assert(m5AttrSelectorMatches("[data-x=RED I]", element))
        @Assert(m5AttrSelectorMatches("[data-x^=r i]", element))
        @Assert(m5AttrSelectorMatches("[data-x$=D i]", element))
        @Assert(m5AttrSelectorMatches("[data-x*=e i]", element))
    }

    /** 三种引号写法：裸标识符、单引号、双引号。 */
    @TestCase
    public func quoteStyles(): Unit {
        let plain = m5RectWith([("data-x", "a b")])
        @Assert(m5AttrSelectorMatches("[data-x='a b']", plain))
        @Assert(m5AttrSelectorMatches("[data-x=\"a b\"]", plain))
        let quoted = m5RectWith([("data-x", "x y z")])
        @Assert(m5AttrSelectorMatches("[data-x='x y z']", quoted))
        @Assert(m5AttrSelectorMatches("[data-x=\"x y z\"]", quoted))
    }

    /** 复合选择器里属性与类型、类、id 并存。 */
    @TestCase
    public func compoundWithAttribute(): Unit {
        let element = m5RectWith([("id", "b"), ("class", "a"), ("data-x", "1")])
        @Assert(m5AttrSelectorMatches("rect.a#b[data-x]", element))
        @Assert(!m5AttrSelectorMatches("rect.a#b[data-y]", element))
        let parts = CssSelector.parse("rect.a#b[data-x]").parts
        @Assert(parts.size == 1)
        @Assert(parts[0].simples.size == 4)
        var sawAttribute = false
        for (simple in parts[0].simples) {
            match (simple) {
                case Attribute(selector) =>
                    sawAttribute = true
                    @Assert(selector.name == "data-x")
                    @Assert(selector.op == CssAttributeOperator.Exists)
                    @Assert(selector.value.isNone())
                    @Assert(!selector.caseInsensitive)
                case _ => ()
            }
        }
        @Assert(sawAttribute)
    }

    /** 非法形式：缺名、缺值、空值都使选择器无效。 */
    @TestCase
    public func invalidFormsAreRejected(): Unit {
        for (selector in ["[=x]", "[data-x=]", "[data-x=\"\"]", "[]", "[data-x", "[data-x=]]"]) {
            var threw = false
            try {
                CssSelector.parse(selector)
            } catch (error: SvgException) {
                threw = error.kind == SvgErrorKind.InvalidValue
            }
            if (!threw) {
                @Fail("非法属性选择器应被拒绝：${selector}")
            }
        }
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("[data-x=] { fill: red }\nrect { fill: blue }", warnings)
        @Assert(sheet.rules.size == 1)
        @Assert(sheet.rules[0].selectors[0].toString() == "rect")
        @Assert(warnings.size >= 1)
        @Assert(warnings[0].contains("data-x"))
    }
}
