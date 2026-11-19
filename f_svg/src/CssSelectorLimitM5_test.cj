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

/** 生成 `count` 个相邻类选择器组成的复合选择器。 */
internal func m5RepeatedClasses(count: Int64): String {
    let out = StringBuilder()
    for (index in 0..count) {
        out.append(".c")
        out.append(index.toString())
    }
    out.toString()
}

/** 生成 `count` 段后代选择器。 */
internal func m5RepeatedDescendants(count: Int64): String {
    let out = StringBuilder()
    for (index in 0..count) {
        if (index > 0) {
            out.append(" ")
        }
        out.append("rect")
    }
    out.toString()
}

@Test
public class CssSelectorLimitM5_test {
    /** 恰好 256 个简单选择器仍可解析。 */
    @TestCase
    public func atLimitIsAccepted(): Unit {
        let selector = m5RepeatedClasses(CSS_MAX_SIMPLE_SELECTORS)
        let parsed = CssSelector.parse(selector)
        @Assert(parsed.parts[0].simples.size == CSS_MAX_SIMPLE_SELECTORS)
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("${selector} { fill: red }", warnings)
        @Assert(sheet.rules.size == 1)
        @Assert(warnings.size == 0)
    }

    /** 257 个类选择器的复合选择器整条跳过。 */
    @TestCase
    public func compoundOverLimitIsSkipped(): Unit {
        let selector = m5RepeatedClasses(CSS_MAX_SIMPLE_SELECTORS + 1)
        var threw = false
        try {
            CssSelector.parse(selector)
        } catch (error: SvgException) {
            threw = error.kind == SvgErrorKind.InvalidValue
        }
        @Assert(threw)
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("${selector} { fill: red }\nrect { fill: blue }", warnings)
        @Assert(sheet.rules.size == 1)
        @Assert(sheet.rules[0].selectors[0].toString() == "rect")
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("256"))
        @Assert(warnings[0].contains(".c0"))
    }

    /** 多段选择器的总简单选择器数也受同一上限约束。 */
    @TestCase
    public func descendantChainOverLimitIsSkipped(): Unit {
        let accepted = m5RepeatedDescendants(CSS_MAX_SIMPLE_SELECTORS)
        @Assert(CssSelector.parse(accepted).parts.size == CSS_MAX_SIMPLE_SELECTORS)
        let rejected = m5RepeatedDescendants(CSS_MAX_SIMPLE_SELECTORS + 1)
        var threw = false
        try {
            CssSelector.parse(rejected)
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("${rejected} { fill: red }", warnings)
        @Assert(sheet.rules.size == 0)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("256"))
    }
}
