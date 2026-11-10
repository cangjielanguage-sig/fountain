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
public class CssVariablesM5_test {
    /** 基本替换。 */
    @TestCase
    public func basicSubstitution(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            ":root { --brand: red } rect { fill: var(--brand) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#ff0000")
    }

    /** 继承与局部覆盖。 */
    @TestCase
    public func inheritanceAndOverride(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g style=\"--c: red; fill: var(--c)\">" +
            "<rect id=\"r\" style=\"--c: blue\"/><circle id=\"c\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#0000ff")
        @Assert(m5StyleOf(tree, document.elementById("c")).fill().toString() == "#ff0000")
    }

    /** fallback：缺省变量取逗号后的值，不产生告警。 */
    @TestCase
    public func fallbackValue(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { fill: var(--missing, green) }</style><rect id=\"r\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#008000")
        @Assert(resolver.warnings.size == 0)
    }

    /** 变量可用于长度与枚举属性，替换后仍走既有归一化。 */
    @TestCase
    public func variablesForLengthsAndKeywords(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            ":root { --w: 4; --cap: round }" +
            "rect { stroke-width: var(--w); stroke-linecap: var(--cap) }</style>" +
            "<rect id=\"r\"/></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.strokeWidth().value == 4.0)
        @Assert(style.strokeLineCap() == SvgLineCap.Round)
    }

    /** 自定义属性名保留大小写，普通属性名转小写。 */
    @TestCase
    public func declarationNameCase(): Unit {
        let sheet = CssStyleSheet.parse("rect { --Brand-Color: red; FILL: blue }")
        @Assert(sheet.rules[0].declarations.size == 2)
        @Assert(sheet.rules[0].declarations[0].property == "--Brand-Color")
        @Assert(sheet.rules[0].declarations[1].property == "fill")
    }

    /** 空值声明无效。 */
    @TestCase
    public func emptyDeclarationIsInvalid(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse("rect { --empty: ; fill: var(--empty) }", warnings)
        @Assert(sheet.rules[0].declarations.size == 1)
        @Assert(sheet.rules[0].declarations[0].property == "fill")
        @Assert(warnings.size >= 1)
    }

    /** 自定义属性本身不参与渲染属性表。 */
    @TestCase
    public func customPropertiesAreNotRendered(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" style=\"--x: red\"/></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.get("--x") == Some("red"))
        @Assert(style.fill().toString() == "#000000")
    }
}
