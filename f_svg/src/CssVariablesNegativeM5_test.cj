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

/** 生成 `--v1: var(--v2); …; --vN: red` 的变量链。 */
internal func m5VariableChain(levels: Int64): String {
    let out = StringBuilder()
    for (index in 1..levels) {
        out.append("--v")
        out.append(index.toString())
        out.append(": var(--v")
        out.append((index + 1).toString())
        out.append("); ")
    }
    out.append("--v")
    out.append(levels.toString())
    out.append(": red;")
    out.toString()
}

internal func m5FilledByVariables(declarations: String): (SvgComputedStyle, ArrayList<String>) {
    let (document, tree, resolver) = m5ComputeStyles(
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>:root { " + declarations +
        " } rect { fill: var(--v1) }</style><rect id=\"r\"/></svg>"
    )
    (m5StyleOf(tree, document.elementById("r")), resolver.warnings)
}

@Test
public class CssVariablesNegativeM5_test {
    /** 循环引用使声明无效并告警。 */
    @TestCase
    public func cycleIsInvalid(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            ":root { --a: var(--b); --b: var(--a) } rect { fill: var(--a) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#000000")
        var sawVar = false
        for (warning in resolver.warnings) {
            if (warning.contains("var")) {
                sawVar = true
            }
        }
        @Assert(sawVar)
    }

    /** 8 层引用有效。 */
    @TestCase
    public func eightLevelsAreAccepted(): Unit {
        let (style, _) = m5FilledByVariables(m5VariableChain(8))
        @Assert(style.fill().toString() == "#ff0000")
    }

    /** 9 层引用超限：声明无效并告警。 */
    @TestCase
    public func nineLevelsAreRejected(): Unit {
        let (style, warnings) = m5FilledByVariables(m5VariableChain(9))
        @Assert(style.fill().toString() == "#000000")
        var sawVar = false
        for (warning in warnings) {
            if (warning.contains("var")) {
                sawVar = true
            }
        }
        @Assert(sawVar)
    }

    /** fallback 内再写 var()。 */
    @TestCase
    public func nestedFallback(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            ":root { --brand: green } rect { fill: var(--missing, var(--brand)) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#008000")
    }

    /** 缺变量且无 fallback 时无效。 */
    @TestCase
    public func missingWithoutFallback(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { fill: var(--nope) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#000000")
        @Assert(resolver.warnings.size >= 1)
    }

    /** 非自定义属性名（不以 -- 开头）视为非法。 */
    @TestCase
    public func invalidReferenceName(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { fill: var(brand) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#000000")
    }

    /** 展开器直接调用的边界行为。 */
    @TestCase
    public func expanderEdges(): Unit {
        @Assert(!containsCssVariable("red"))
        @Assert(containsCssVariable("var(--x)"))
        let none = expandCssVariables("var(--x)", {_ => None}, Array<String>(), 0)
        @Assert(none.isNone())
        let plain = expandCssVariables("1px", {_ => None}, Array<String>(), 0)
        @Assert(plain == Some("1px"))
        let fallback = expandCssVariables("var(--x, 2px)", {_ => None}, Array<String>(), 0)
        @Assert(fallback == Some("2px"))
    }
}
