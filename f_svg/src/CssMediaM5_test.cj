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

/** 规则携带的媒体条件是否在给定宽度下生效。 */
internal func m5RuleMatches(rule: CssRule, width: Float64): Bool {
    match (rule.media) {
        case Some(media) => media.matches(width)
        case None => true
    }
}

@Test
public class CssMediaM5_test {
    /** screen / all 命中，print 不命中。 */
    @TestCase
    public func mediaTypes(): Unit {
        let warnings = ArrayList<String>()
        let screen = CssStyleSheet.parse("@media screen { rect { fill: red } }", warnings)
        @Assert(screen.rules.size == 1)
        @Assert(screen.rules[0].media.isSome())
        @Assert(m5RuleMatches(screen.rules[0], 800.0))
        @Assert(warnings.size == 0)

        let all = CssStyleSheet.parse("@media all { rect { fill: red } }", warnings)
        @Assert(m5RuleMatches(all.rules[0], 300.0))

        let print = CssStyleSheet.parse("@media print { rect { fill: red } }", warnings)
        @Assert(print.rules.size == 1)
        @Assert(!m5RuleMatches(print.rules[0], 800.0))
        @Assert(warnings.size == 0)
    }

    /** `and` 连接的条件必须同时满足。 */
    @TestCase
    public func conjunction(): Unit {
        let sheet = CssStyleSheet.parse(
            "@media screen and (min-width: 600px) { rect { fill: red } }"
        )
        @Assert(sheet.rules.size == 1)
        @Assert(m5RuleMatches(sheet.rules[0], 800.0))
        @Assert(!m5RuleMatches(sheet.rules[0], 599.5))
        @Assert(m5RuleMatches(sheet.rules[0], 600.0))
        @Assert(m5RuleMatches(sheet.rules[0], 600.5))
    }

    /** 逗号列表是「或」语义。 */
    @TestCase
    public func commaList(): Unit {
        let sheet = CssStyleSheet.parse(
            "@media (max-width: 500px), (min-width: 1000px) { rect { fill: red } }"
        )
        @Assert(sheet.rules.size == 1)
        @Assert(m5RuleMatches(sheet.rules[0], 400.0))
        @Assert(!m5RuleMatches(sheet.rules[0], 800.0))
        @Assert(m5RuleMatches(sheet.rules[0], 1200.0))
    }

    /** max-width 上界。 */
    @TestCase
    public func maxWidth(): Unit {
        let sheet = CssStyleSheet.parse("@media screen and (max-width: 400px) { rect { fill: red } }")
        @Assert(m5RuleMatches(sheet.rules[0], 400.0))
        @Assert(m5RuleMatches(sheet.rules[0], 399.5))
        @Assert(!m5RuleMatches(sheet.rules[0], 400.5))
    }

    /** 媒体块内多条规则按展开后的源顺序递增。 */
    @TestCase
    public func sourceOrderExpands(): Unit {
        let sheet = CssStyleSheet.parse(
            "@media screen { rect { fill: red } circle { fill: green } } g { fill: blue }"
        )
        @Assert(sheet.rules.size == 3)
        @Assert(sheet.rules[0].order == 0)
        @Assert(sheet.rules[1].order == 1)
        @Assert(sheet.rules[2].order == 2)
        @Assert(sheet.rules[2].media.isNone())
    }

    /** 媒体块内的选择器与声明照常解析。 */
    @TestCase
    public func declarationsInsideMedia(): Unit {
        let sheet = CssStyleSheet.parse(
            "@media screen { rect[data-k]:not(.skip) { fill: red !important; stroke: blue } }"
        )
        @Assert(sheet.rules.size == 1)
        @Assert(sheet.rules[0].selectors.size == 1)
        @Assert(sheet.rules[0].declarations.size == 2)
        @Assert(sheet.rules[0].declarations[0].important)
    }

    /** 非法查询跳过并记 warning，其余规则不受影响。 */
    @TestCase
    public func invalidQuery(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@media screen and (min-width: abc) { rect { fill: red } }\n" +
            "@media screen and (min-width: 100px) { circle { fill: green } }\n" +
            "g { fill: blue }",
            warnings
        )
        @Assert(sheet.rules.size == 2)
        @Assert(m5RuleMatches(sheet.rules[0], 800.0))
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("@media"))
        @Assert(warnings[0].contains("min-width"))
    }

    /** 不支持的 at-rule 仍然跳过。 */
    @TestCase
    public func importStillSkipped(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@import url(\"a.css\"); @media screen { rect { fill: red } }",
            warnings
        )
        @Assert(sheet.rules.size == 1)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("@import"))
    }

    /** 媒体查询文本可往返。 */
    @TestCase
    public func queryToString(): Unit {
        let media = CssMediaQuery.parse("screen and (min-width: 600px), print")
        @Assert(media.isSome())
        match (media) {
            case Some(value) =>
                @Assert(value.toString().contains("screen"))
                @Assert(value.toString().contains("600"))
                @Assert(value.toString().contains("print"))
            case None => @Fail("合法媒体查询不应返回 None")
        }
    }
}
