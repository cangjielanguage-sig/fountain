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

/** 返回组内匹配选择器的元素下标（0 起，按文档顺序）。 */
internal func m5MatchedIndices(selector: String, group: SvgElement): Array<Int64> {
    let parsed = CssSelector.parse(selector)
    let result = ArrayList<Int64>()
    var index = 0
    for (node in group.children) {
        match (node) {
            case ElementNode(child) =>
                if (parsed.matches(child)) {
                    result.add(index)
                }
                index++
            case _ => ()
        }
    }
    result.toArray()
}

@Test
public class CssSelectorNthM5_test {
    private func fiveChildren(): SvgContainer {
        m5GroupOf([SvgRect(), SvgCircle(), SvgRect(), SvgCircle(), SvgRect()])
    }

    /** odd / even / 2n+1 的等价性与奇偶。 */
    @TestCase
    public func oddAndEven(): Unit {
        let group = fiveChildren()
        @Assert(m5MatchedIndices(":nth-child(odd)", group) == [0, 2, 4])
        @Assert(m5MatchedIndices(":nth-child(2n+1)", group) == [0, 2, 4])
        @Assert(m5MatchedIndices(":nth-child(even)", group) == [1, 3])
        @Assert(m5MatchedIndices(":nth-child(2n)", group) == [1, 3])
        @Assert(m5MatchedIndices(":nth-child(2n + 1)", group) == [0, 2, 4])
    }

    /** 负系数与纯 n。 */
    @TestCase
    public func negativeAndBareN(): Unit {
        let group = fiveChildren()
        @Assert(m5MatchedIndices(":nth-child(-n+2)", group) == [0, 1])
        @Assert(m5MatchedIndices(":nth-child(-n + 3)", group) == [0, 1, 2])
        @Assert(m5MatchedIndices(":nth-child(n)", group) == [0, 1, 2, 3, 4])
        @Assert(m5MatchedIndices(":nth-child(3)", group) == [2])
        @Assert(m5MatchedIndices(":nth-child(0)", group) == Array<Int64>())
        @Assert(m5MatchedIndices(":nth-child(10)", group) == Array<Int64>())
        @Assert(m5MatchedIndices(":nth-child(-2n+4)", group) == [1, 3])
    }

    /** nth-of-type 只按同标签兄弟计数。 */
    @TestCase
    public func nthOfType(): Unit {
        let group = fiveChildren()
        @Assert(m5MatchedIndices("rect:nth-of-type(1)", group) == [0])
        @Assert(m5MatchedIndices("rect:nth-of-type(2)", group) == [2])
        @Assert(m5MatchedIndices("rect:nth-of-type(3)", group) == [4])
        @Assert(m5MatchedIndices("circle:nth-of-type(odd)", group) == [1])
        @Assert(m5MatchedIndices("circle:nth-of-type(even)", group) == [3])
    }

    /** An+B 解析结果可供断言。 */
    @TestCase
    public func anBParsing(): Unit {
        @Assert(parseCssAnB("odd") == Some([2, 1]))
        @Assert(parseCssAnB("even") == Some([2, 0]))
        @Assert(parseCssAnB("2n+1") == Some([2, 1]))
        @Assert(parseCssAnB("-n+2") == Some([-1, 2]))
        @Assert(parseCssAnB("n") == Some([1, 0]))
        @Assert(parseCssAnB("+n-3") == Some([1, -3]))
        @Assert(parseCssAnB("7") == Some([0, 7]))
        @Assert(parseCssAnB("-n") == Some([-1, 0]))
        @Assert(parseCssAnB("ODD") == Some([2, 1]))
    }

    /** 非法表达式：规则被跳过并 warning。 */
    @TestCase
    public func invalidAnB(): Unit {
        for (expression in ["2n+", "n+", "++2", "3n-", "", "n+n", "2m+1"]) {
            @Assert(parseCssAnB(expression).isNone())
            var threw = false
            try {
                CssSelector.parse(":nth-child(${expression})")
            } catch (_: SvgException) {
                threw = true
            }
            if (!threw) {
                @Fail("应拒绝非法 An+B：${expression}")
            }
        }
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            ":nth-child(2n+) { fill: red }\nrect { fill: blue }",
            warnings
        )
        @Assert(sheet.rules.size == 1)
        @Assert(warnings.size >= 1)
        @Assert(warnings[0].contains("nth-child"))
    }
}
