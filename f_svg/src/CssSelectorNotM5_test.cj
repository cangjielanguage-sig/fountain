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
public class CssSelectorNotM5_test {
    /** 排除类：只有无该类名的元素匹配。 */
    @TestCase
    public func excludeClass(): Unit {
        let skipped = SvgRect()
        skipped.className = "skip"
        let plain = SvgRect()
        let group = m5GroupOf([skipped, plain])
        @Assert(!m5AttrSelectorMatches("rect:not(.skip)", skipped))
        @Assert(m5AttrSelectorMatches("rect:not(.skip)", plain))
        @Assert(m5AttrSelectorMatches("rect:not(.other)", skipped))
    }

    /** 否定结构伪类：同一兄弟上下文求值。 */
    @TestCase
    public func excludeStructuralPseudo(): Unit {
        let first = SvgRect()
        let second = SvgRect()
        m5GroupOf([first, second])
        @Assert(!m5AttrSelectorMatches("rect:not(:first-child)", first))
        @Assert(m5AttrSelectorMatches("rect:not(:first-child)", second))
        @Assert(m5AttrSelectorMatches("rect:not(:last-child)", first))
        @Assert(!m5AttrSelectorMatches("rect:not(:last-child)", second))
        @Assert(!m5AttrSelectorMatches("rect:not(:nth-child(2))", second))
        @Assert(m5AttrSelectorMatches("rect:not(:nth-child(3))", second))
    }

    /** 参数支持类型、`*`、id、属性。 */
    @TestCase
    public func argumentKinds(): Unit {
        let rect = SvgRect()
        rect.setAttr("id", "r")
        rect.setAttr("data-x", "1")
        let group = m5GroupOf([rect])
        @Assert(!m5AttrSelectorMatches(":not(rect)", rect))
        @Assert(!m5AttrSelectorMatches(":not(*)", rect))
        @Assert(!m5AttrSelectorMatches(":not(#r)", rect))
        @Assert(m5AttrSelectorMatches(":not(#other)", rect))
        @Assert(!m5AttrSelectorMatches(":not([data-x])", rect))
        @Assert(m5AttrSelectorMatches(":not([data-y])", rect))
        @Assert(!m5AttrSelectorMatches(":not([data-x=1])", rect))
    }

    /** 嵌套、复合参数与空参数都被拒绝。 */
    @TestCase
    public func invalidArguments(): Unit {
        for (selector in [":not(:not(.a))", ":not(.a.b)", ":not(rect.a)", ":not()", ":not(.a .b)"]) {
            var threw = false
            try {
                CssSelector.parse(selector)
            } catch (_: SvgException) {
                threw = true
            }
            if (!threw) {
                @Fail("应拒绝 :not() 参数：${selector}")
            }
        }
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(":not(:not(.a)) { fill: red }\nrect { fill: blue }", warnings)
        @Assert(sheet.rules.size == 1)
        @Assert(warnings.size >= 1)
        @Assert(warnings[0].contains("not"))
    }
}
