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
public class CssFontFaceM5_test {
    /** 完整声明：family / weight / style 与 src 标记。 */
    @TestCase
    public func parseFullRule(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@font-face { font-family: Body; font-weight: bold; font-style: italic; " +
            "src: url(x.ttf) format(\"truetype\") }",
            warnings
        )
        @Assert(sheet.rules.size == 0)
        @Assert(sheet.fontFaces.size == 1)
        let rule = sheet.fontFaces[0]
        @Assert(rule.family == "Body")
        @Assert(rule.weight == Some("bold"))
        @Assert(rule.style == Some("italic"))
        @Assert(rule.srcPresent)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("src"))
    }

    /** 可选字段缺省与不带 src 时不产生 src 告警。 */
    @TestCase
    public func optionalFields(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("@font-face { font-family: \"Body Text\" }", warnings)
        @Assert(sheet.fontFaces.size == 1)
        @Assert(sheet.fontFaces[0].family == "Body Text")
        @Assert(sheet.fontFaces[0].weight.isNone())
        @Assert(sheet.fontFaces[0].style.isNone())
        @Assert(!sheet.fontFaces[0].srcPresent)
        @Assert(warnings.size == 0)
    }

    /** 缺少 family 的规则被跳过并告警。 */
    @TestCase
    public func missingFamily(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@font-face { font-weight: bold; src: url(x.ttf) }\nrect { fill: red }",
            warnings
        )
        @Assert(sheet.fontFaces.size == 0)
        @Assert(sheet.rules.size == 1)
        @Assert(warnings.size >= 1)
        var sawFamilyWarning = false
        for (warning in warnings) {
            if (warning.contains("font-family")) {
                sawFamilyWarning = true
            }
        }
        @Assert(sawFamilyWarning)
    }

    /** 多条 font-face 保留源顺序，其他 at-rule 仍跳过。 */
    @TestCase
    public func multipleRulesAndOtherAtRules(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@font-face { font-family: A }\n" +
            "@import url(a.css);\n" +
            "@font-face { font-family: B; src: url(b.ttf) }",
            warnings
        )
        @Assert(sheet.fontFaces.size == 2)
        @Assert(sheet.fontFaces[0].family == "A")
        @Assert(sheet.fontFaces[1].family == "B")
        @Assert(warnings.size == 2)
    }

    /** 与普通规则混排时顺序与告警互不影响。 */
    @TestCase
    public func mixedWithRules(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "rect { fill: red }\n" +
            "@font-face { font-family: Body; src: url(x.ttf) }\n" +
            "@media screen { circle { fill: blue } }",
            warnings
        )
        @Assert(sheet.rules.size == 2)
        @Assert(sheet.rules[0].order == 0)
        @Assert(sheet.rules[1].order == 1)
        @Assert(sheet.fontFaces.size == 1)
        @Assert(warnings.size == 1)
    }
}
