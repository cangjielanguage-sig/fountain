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

/** `<rect/><circle/><rect/>` 结构，返回三个兄弟。 */
internal func m5ThreeSiblings(): Array<SvgElement> {
    let first = SvgRect()
    let middle = SvgCircle()
    let last = SvgRect()
    m5GroupOf([first, middle, last])
    [first, middle, last]
}

@Test
public class CssSelectorSiblingM5_test {
    /** 相邻兄弟 +。 */
    @TestCase
    public func adjacentSibling(): Unit {
        let siblings = m5ThreeSiblings()
        @Assert(!m5AttrSelectorMatches("rect + circle", siblings[0]))
        @Assert(m5AttrSelectorMatches("rect + circle", siblings[1]))
        @Assert(!m5AttrSelectorMatches("rect + circle", siblings[2]))
        @Assert(m5AttrSelectorMatches("circle + rect", siblings[2]))
        @Assert(!m5AttrSelectorMatches("circle + rect", siblings[0]))
        @Assert(m5AttrSelectorMatches("rect+circle", siblings[1]))
        @Assert(m5AttrSelectorMatches("rect  +   circle", siblings[1]))
    }

    /** 一般兄弟 ~。 */
    @TestCase
    public func generalSibling(): Unit {
        let first = SvgRect()
        let middle = SvgContainer(SvgContainerKind.Group)
        let last = SvgCircle()
        m5GroupOf([first, middle, last])
        @Assert(m5AttrSelectorMatches("rect ~ circle", last))
        @Assert(!m5AttrSelectorMatches("circle ~ rect", last))
        @Assert(!m5AttrSelectorMatches("circle ~ rect", first))
        @Assert(m5AttrSelectorMatches("rect ~ circle", last))
        @Assert(m5AttrSelectorMatches("rect ~ g", middle))
    }

    /** 文本与注释节点穿插不影响元素兄弟判定。 */
    @TestCase
    public func textNodesBetween(): Unit {
        let svg = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        let first = SvgRect()
        group.appendElement(first)
        group.appendText("  \n ")
        group.appendChild(SvgNode.CommentNode("note"))
        let second = SvgCircle()
        group.appendElement(second)
        svg.appendElement(group)
        @Assert(m5AttrSelectorMatches("rect + circle", second))
        @Assert(m5AttrSelectorMatches("rect ~ circle", second))
    }

    /** 跨父元素不匹配。 */
    @TestCase
    public func crossParentDoesNotMatch(): Unit {
        let svg = SvgRoot()
        let outer = SvgContainer(SvgContainerKind.Group)
        let inner = SvgContainer(SvgContainerKind.Group)
        let rect = SvgRect()
        inner.appendElement(rect)
        outer.appendElement(inner)
        let circle = SvgCircle()
        outer.appendElement(circle)
        svg.appendElement(outer)
        @Assert(!m5AttrSelectorMatches("rect + circle", circle))
        @Assert(!m5AttrSelectorMatches("rect ~ circle", circle))
    }

    /** 链式组合与 toString 往返。 */
    @TestCase
    public func chainAndToString(): Unit {
        let siblings = m5ThreeSiblings()
        @Assert(m5AttrSelectorMatches("rect + circle + rect", siblings[2]))
        @Assert(!m5AttrSelectorMatches("circle + circle + rect", siblings[2]))
        let parsed = CssSelector.parse("rect + circle ~ rect")
        @Assert(parsed.combinators.size == 2)
        @Assert(parsed.combinators[0] == CssCombinator.AdjacentSibling)
        @Assert(parsed.combinators[1] == CssCombinator.GeneralSibling)
        @Assert(parsed.toString() == "rect + circle ~ rect")
    }

    /** 组合符两侧缺项被拒绝。 */
    @TestCase
    public func danglingCombinatorRejected(): Unit {
        for (selector in ["+ circle", "rect +", "rect ~", "rect ++ circle"]) {
            var threw = false
            try {
                CssSelector.parse(selector)
            } catch (_: SvgException) {
                threw = true
            }
            if (!threw) {
                @Fail("应拒绝组合符：${selector}")
            }
        }
    }
}
