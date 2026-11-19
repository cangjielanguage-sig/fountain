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

internal func m5StyleWith(styleText: String, elementText: String): SvgComputedStyle {
    let (document, tree, _) = m5ComputeStyles(
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" + styleText + "</style>" +
        "<rect id=\"r\" " + elementText + "/></svg>"
    )
    m5StyleOf(tree, document.elementById("r"))
}

@Test
public class CssCalcM5_test {
    /** 四则运算与乘法优先级。 */
    @TestCase
    public func arithmetic(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc(10px + 2 * 3px) }", "")
        @Assert(style.strokeWidth().value == 16.0)
        @Assert(style.strokeWidth().unit == SvgLengthUnit.Px)
    }

    /** em 按当前字号换算。 */
    @TestCase
    public func emConversion(): Unit {
        let style = m5StyleWith(
            "rect { font-size: 20px; letter-spacing: calc(1em - 5px) }",
            ""
        )
        @Assert(style.letterSpacing().value == 15.0)
    }

    /** 括号改变结合顺序。 */
    @TestCase
    public func parentheses(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc((10px + 5px) * 2) }", "")
        @Assert(style.strokeWidth().value == 30.0)
    }

    /** 百分比结果保持百分比。 */
    @TestCase
    public func percentages(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc(50% + 10%) }", "")
        @Assert(style.strokeWidth().unit == SvgLengthUnit.Percent)
        @Assert(style.strokeWidth().value == 60.0)
    }

    /** 百分比与绝对长度混用无效，回退初始值并告警。 */
    @TestCase
    public func mixedUnitsAreInvalid(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { stroke-width: calc(50% + 10px) }</style><rect id=\"r\"/></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.strokeWidth().value == 1.0)
        var sawCalc = false
        for (warning in resolver.warnings) {
            if (warning.contains("calc")) {
                sawCalc = true
            }
        }
        @Assert(sawCalc)
    }

    /** 除零无效。 */
    @TestCase
    public func divisionByZero(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc(10px / 0) }", "")
        @Assert(style.strokeWidth().value == 1.0)
    }

    /** 16 层括号有效，17 层无效。 */
    @TestCase
    public func nestingLimit(): Unit {
        let sixteen = m5Parens(16)
        @Assert(evaluateCssCalc("${sixteen}10px${m5Closers(16)}", 16.0).isSome())
        let seventeen = m5Parens(17)
        @Assert(evaluateCssCalc("${seventeen}10px${m5Closers(17)}", 16.0).isNone())
    }

    private func m5Parens(count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append("(")
        }
        out.toString()
    }

    private func m5Closers(count: Int64): String {
        let out = StringBuilder()
        for (_ in 0..count) {
            out.append(")")
        }
        out.toString()
    }

    /** calc 只用于长度属性；颜色里出现按非法值处理。 */
    @TestCase
    public func calcNotAllowedOnColors(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { fill: calc(1px) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#000000")
        @Assert(resolver.warnings.size >= 1)
    }

    /** 求值器直接行为。 */
    @TestCase
    public func evaluatorEdges(): Unit {
        @Assert(evaluateCssCalc("2 * 3", 16.0) == Some("6"))
        @Assert(evaluateCssCalc("10px / 2", 16.0) == Some("5px"))
        @Assert(evaluateCssCalc("1em", 16.0) == Some("16px"))
        @Assert(evaluateCssCalc("50%", 16.0) == Some("50%"))
        @Assert(evaluateCssCalc("10px / 0", 16.0).isNone())
        @Assert(evaluateCssCalc("2n", 16.0).isNone())
        @Assert(evaluateCssCalc("10px + 5", 16.0).isNone())
        @Assert(evaluateCssCalc("-10px + 20px", 16.0) == Some("10px"))
    }
}
