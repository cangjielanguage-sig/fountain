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
public class CssStyleSheet_test {
    /** 基本规则、分组、声明原样值与源顺序。 */
    @TestCase
    public func basicRulesAndOrder(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "rect { fill: red; stroke: blue }\n" +
            "circle.a, #b { font-family: \"A B\", serif }\n" +
            ".c { opacity: 0.5 }",
            warnings
        )
        @Assert(sheet.rules.size == 3)
        @Assert(warnings.size == 0)
        @Assert(sheet.rules[0].selectors.size == 1)
        @Assert(sheet.rules[0].declarations.size == 2)
        @Assert(sheet.rules[0].declarations[0].property == "fill")
        @Assert(sheet.rules[0].declarations[0].value == "red")
        @Assert(sheet.rules[0].declarations[1].property == "stroke")
        @Assert(sheet.rules[1].selectors.size == 2)
        @Assert(sheet.rules[1].declarations[0].value == "\"A B\", serif")
        @Assert(sheet.rules[0].order < sheet.rules[1].order)
        @Assert(sheet.rules[1].order < sheet.rules[2].order)
        @Assert(sheet.rules[0].toString().contains("rect"))
    }

    /** !important 只影响标志位，值不保留后缀。 */
    @TestCase
    public func importantDeclarations(): Unit {
        let sheet = CssStyleSheet.parse("rect { fill: red !important; stroke: blue }")
        @Assert(sheet.rules[0].declarations[0].important)
        @Assert(sheet.rules[0].declarations[0].value == "red")
        @Assert(!sheet.rules[0].declarations[1].important)
        @Assert(sheet.rules[0].declarations[1].value == "blue")
        let spaced = CssStyleSheet.parse("rect { fill: red ! important }")
        @Assert(spaced.rules[0].declarations[0].important)
        @Assert(spaced.rules[0].declarations[0].value == "red")
    }

    /** @media / @import / @font-face 整条跳过并写 warning。 */
    @TestCase
    public func atRulesAreSkipped(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@import url(\"a.css\");\n" +
            "@media screen { rect { fill: red } }\n" +
            "@font-face { font-family: X }\n" +
            "circle { fill: blue }",
            warnings
        )
        @Assert(sheet.rules.size == 1)
        @Assert(sheet.rules[0].selectors[0].toString().startsWith("circle"))
        @Assert(warnings.size == 3)
    }

    /** 伪类与属性选择器整条跳过。 */
    @TestCase
    public func unsupportedSelectorsAreSkipped(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "rect:hover { fill: red }\n" +
            "rect[width] { fill: green }\n" +
            "g > circle { fill: blue }",
            warnings
        )
        @Assert(sheet.rules.size == 1)
        @Assert(sheet.rules[0].selectors[0].toString() == "g > circle")
        @Assert(warnings.size == 2)
    }

    /** 缺右花括号、缺分号、空块、多余分号。 */
    @TestCase
    public func tolerantParsing(): Unit {
        let warnings = ArrayList<String>()
        let truncated = CssStyleSheet.parse("rect { fill: red", warnings)
        @Assert(truncated.rules.size == 1)
        @Assert(truncated.rules[0].declarations.size == 1)
        @Assert(warnings.size >= 1)

        let sheet = CssStyleSheet.parse("rect { fill: red; stroke: blue }")
        @Assert(sheet.rules[0].declarations.size == 2)

        let empty = CssStyleSheet.parse("rect {}")
        @Assert(empty.rules.size == 1)
        @Assert(empty.rules[0].declarations.size == 0)

        let semis = CssStyleSheet.parse("rect {;; fill: red ;;; stroke: blue ;;}")
        @Assert(semis.rules[0].declarations.size == 2)

        let missingColon = CssStyleSheet.parse("rect { fill red; stroke: blue }", warnings)
        @Assert(missingColon.rules[0].declarations.size == 1)
        @Assert(missingColon.rules[0].declarations[0].property == "stroke")
    }

    /** 空样式表与稳定输出。 */
    @TestCase
    public func emptyAndToString(): Unit {
        @Assert(CssStyleSheet.empty().rules.size == 0)
        @Assert(CssStyleSheet.parse("").rules.size == 0)
        @Assert(CssStyleSheet.parse("  /* only comment */ ").rules.size == 0)
        @Assert(CssStyleSheet.parse("rect, circle { fill: red; }").toString() == "rect, circle { fill: red; }")
        @Assert(CssStyleSheet.parse("rect {}").toString() == "rect {}")
    }
}
