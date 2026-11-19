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
public class CssCalcPropertyM5_test {
    /** font-size 的 calc 以父字号换算 em。 */
    @TestCase
    public func fontSizeCalc(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g style=\"font-size: 20px\">" +
            "<rect id=\"r\" style=\"font-size: calc(1em + 4px)\"/></g></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fontSize().value == 24.0)
        @Assert(style.fontSize().unit == SvgLengthUnit.Px)
    }

    /** stroke-width / letter-spacing 结果可被 SvgLength 解析。 */
    @TestCase
    public func lengthPropertiesAreParsable(): Unit {
        let style = m5StyleWith(
            "rect { stroke-width: calc(2px * 2.5); letter-spacing: calc(10px / 4) }",
            ""
        )
        @Assert(SvgLength.tryParse(style.get("stroke-width") ?? "").isSome())
        @Assert(style.strokeWidth().value == 5.0)
        @Assert(style.letterSpacing().value == 2.5)
    }

    /** calc 内部可以使用 var()。 */
    @TestCase
    public func calcWithVariables(): Unit {
        let style = m5StyleWith(
            ":root { --w: 10px } rect { stroke-width: calc(var(--w) * 2) }",
            ""
        )
        @Assert(style.strokeWidth().value == 20.0)
    }

    /** 非法表达式回退初始值并告警。 */
    @TestCase
    public func invalidExpressionFallsBack(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { stroke-width: calc(10px * 2px) }</style><rect id=\"r\"/></svg>"
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

    /** 未闭合的 calc 按非法值处理。 */
    @TestCase
    public func unclosedExpression(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc(10px }", "")
        @Assert(style.strokeWidth().value == 1.0)
    }

    /** 百分比结果在长度属性上保留百分比语义。 */
    @TestCase
    public func percentageLength(): Unit {
        let style = m5StyleWith("rect { stroke-width: calc(25% * 2) }", "")
        @Assert(style.strokeWidth().unit == SvgLengthUnit.Percent)
        @Assert(style.strokeWidth().value == 50.0)
    }
}
