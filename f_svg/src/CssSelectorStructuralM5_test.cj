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

/** 构造 `<svg><g>…children…</g></svg>` 并返回组。 */
internal func m5GroupOf(children: Array<SvgElement>): SvgContainer {
    let svg = SvgRoot()
    let group = SvgContainer(SvgContainerKind.Group)
    for (child in children) {
        group.appendElement(child)
    }
    svg.appendElement(group)
    group
}

@Test
public class CssSelectorStructuralM5_test {
    /** first / last / only-child 只按元素兄弟计数。 */
    @TestCase
    public func firstAndLastChild(): Unit {
        let first = SvgRect()
        let middle = SvgCircle()
        let last = SvgRect()
        let group = m5GroupOf([first, middle, last])
        @Assert(m5AttrSelectorMatches(":first-child", first))
        @Assert(!m5AttrSelectorMatches(":first-child", middle))
        @Assert(m5AttrSelectorMatches(":last-child", last))
        @Assert(!m5AttrSelectorMatches(":last-child", middle))
        @Assert(!m5AttrSelectorMatches(":only-child", middle))
        @Assert(m5AttrSelectorMatches("rect:first-child", first))
        @Assert(m5AttrSelectorMatches("circle:last-child", middle) == false)
    }

    /** 文本与注释节点不参与计数。 */
    @TestCase
    public func textAndCommentNodesAreIgnored(): Unit {
        let svg = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        group.appendText("  \n ")
        group.appendChild(SvgNode.CommentNode("note"))
        let first = SvgRect()
        group.appendElement(first)
        group.appendText("tail")
        let second = SvgCircle()
        group.appendElement(second)
        svg.appendElement(group)
        @Assert(m5AttrSelectorMatches(":first-child", first))
        @Assert(!m5AttrSelectorMatches(":first-child", second))
        @Assert(m5AttrSelectorMatches(":last-child", second))
    }

    /** only-child 与 of-type 三种形态。 */
    @TestCase
    public func onlyChildAndOfType(): Unit {
        let first = SvgRect()
        let middle = SvgCircle()
        let last = SvgRect()
        m5GroupOf([first, middle, last])
        @Assert(!m5AttrSelectorMatches(":only-child", middle))
        @Assert(m5AttrSelectorMatches(":only-of-type", middle))
        @Assert(m5AttrSelectorMatches("rect:first-of-type", first))
        @Assert(!m5AttrSelectorMatches("rect:first-of-type", last))
        @Assert(m5AttrSelectorMatches("rect:last-of-type", last))
        @Assert(!m5AttrSelectorMatches("rect:last-of-type", first))
        @Assert(m5AttrSelectorMatches("circle:only-of-type", middle))
        @Assert(!m5AttrSelectorMatches("circle:first-of-type", first))

        let lone = SvgRect()
        m5GroupOf([lone])
        @Assert(m5AttrSelectorMatches(":only-child", lone))
        @Assert(m5AttrSelectorMatches(":only-of-type", lone))
    }

    /** :root 只匹配无父元素的根。 */
    @TestCase
    public func root(): Unit {
        let svg = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        svg.appendElement(group)
        @Assert(m5AttrSelectorMatches(":root", svg))
        @Assert(m5AttrSelectorMatches("svg:root", svg))
        @Assert(!m5AttrSelectorMatches(":root", group))
        @Assert(!m5AttrSelectorMatches("g:root", group))
    }

    /** :empty 忽略空白文本、注释与 PI。 */
    @TestCase
    public func empty(): Unit {
        let blank = SvgContainer(SvgContainerKind.Group)
        blank.appendText(" \n\t ")
        blank.appendChild(SvgNode.CommentNode("c"))
        let holder = SvgRoot()
        holder.appendElement(blank)
        @Assert(m5AttrSelectorMatches(":empty", blank))

        let withChild = SvgContainer(SvgContainerKind.Group)
        withChild.appendElement(SvgRect())
        let holder2 = SvgRoot()
        holder2.appendElement(withChild)
        @Assert(!m5AttrSelectorMatches(":empty", withChild))

        let withText = SvgContainer(SvgContainerKind.Group)
        withText.appendText("x")
        let holder3 = SvgRoot()
        holder3.appendElement(withText)
        @Assert(!m5AttrSelectorMatches(":empty", withText))
    }

    /** 伪类可与其他简单选择器组合。 */
    @TestCase
    public func compoundWithPseudo(): Unit {
        let rect = SvgRect()
        rect.setAttr("class", "a")
        let group = m5GroupOf([rect, SvgCircle()])
        @Assert(m5AttrSelectorMatches("rect.a:first-child", rect))
        @Assert(!m5AttrSelectorMatches("rect.a:last-child", rect))
        @Assert(m5AttrSelectorMatches("g > rect:first-child", rect))
        let parts = CssSelector.parse("rect:first-child").parts
        @Assert(parts[0].simples.size == 2)
        match (parts[0].simples[1]) {
            case PseudoClass(pseudo) => @Assert(pseudo == CssPseudoClass.FirstChild)
            case _ => @Fail("第二个简单选择器应为伪类")
        }
    }

    /** 未知伪类与伪元素被拒绝。 */
    @TestCase
    public func unknownPseudoIsRejected(): Unit {
        for (selector in [":hover", "::before", ":nth-child", ":nth-child()", ":not()"]) {
            var threw = false
            try {
                CssSelector.parse(selector)
            } catch (_: SvgException) {
                threw = true
            }
            if (!threw) {
                @Fail("应拒绝伪类选择器：${selector}")
            }
        }
    }
}
