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
public class CssInteractionM6_test {
    private func rootWith(children: Array<SvgElement>): SvgRoot {
        let root = SvgRoot()
        for (child in children) {
            root.appendElement(child)
        }
        root
    }

    /** `:hover` / `:focus` 可解析并往返。 */
    @TestCase
    public func parsePseudoClasses(): Unit {
        @Assert(CssSelector.parse(":hover").toString() == ":hover")
        @Assert(CssSelector.parse(":focus").toString() == ":focus")
        @Assert(CssSelector.parse("rect.a:hover").toString() == "rect.a:hover")
        @Assert(CssSelector.parse("rect:focus").toString() == "rect:focus")
        @Assert(CssSelector.parse(":not(:hover)").toString() == ":not(:hover)")
    }

    /** 交互伪类的特异性与结构伪类一致：类型列 +1。 */
    @TestCase
    public func specificity(): Unit {
        let selector = CssSelector.parse("rect:hover")
        @Assert(selector.specificity == CssSpecificity(0, 0, 2))
        @Assert(CssSelector.parse("*:hover").specificity == CssSpecificity(0, 0, 1))
        @Assert(CssSelector.parse("#x:hover").specificity == CssSpecificity(1, 0, 1))
        @Assert(CssSelector.parse(":hover").specificity == CssSpecificity(0, 0, 1))
    }

    /** 空状态永不匹配交互伪类，` :not()` 相应恒为真。 */
    @TestCase
    public func emptyStateNeverMatches(): Unit {
        let rect = SvgRect()
        rect.setAttr("id", "r")
        rootWith([rect])
        let empty = SvgInteractionState.empty()
        @Assert(!CssSelector.parse(":hover").matches(rect, empty))
        @Assert(!CssSelector.parse(":focus").matches(rect, empty))
        @Assert(CssSelector.parse(":not(:hover)").matches(rect, empty))
        @Assert(CssSelector.parse(":not(:focus)").matches(rect, empty))
    }

    /** hoveredIds 按 id 命中，无 id 元素永不匹配。 */
    @TestCase
    public func hoverMatchesById(): Unit {
        let rect = SvgRect()
        rect.setAttr("id", "r")
        let plain = SvgRect()
        let root = rootWith([rect, plain])
        let state = SvgInteractionState(hoveredIds: ["r"], root: root)
        @Assert(CssSelector.parse(":hover").matches(rect, state))
        @Assert(!CssSelector.parse(":hover").matches(plain, state))
        @Assert(CssSelector.parse("rect:hover").matches(rect, state))
        @Assert(CssSelector.parse("circle:hover").matches(rect, state) == false)
        @Assert(CssSelector.parse(":not(:hover)").matches(plain, state))
    }

    /** `:focus` 只匹配第一个可解析的 id。 */
    @TestCase
    public func focusOnlyFirstResolvable(): Unit {
        let first = SvgRect()
        first.setAttr("id", "a")
        let second = SvgRect()
        second.setAttr("id", "b")
        let root = rootWith([first, second])
        let state = SvgInteractionState(focusedIds: ["missing", "a", "b"], root: root)
        @Assert(CssSelector.parse(":focus").matches(first, state))
        @Assert(!CssSelector.parse(":focus").matches(second, state))
    }

    /** 复合选择器与 `:not()` 透传同一交互状态。 */
    @TestCase
    public func compoundAndNot(): Unit {
        let rect = SvgRect()
        rect.setAttr("id", "r")
        rect.className = "hot"
        rootWith([rect])
        let state = SvgInteractionState(hoveredIds: ["r"], focusedIds: ["r"])
        @Assert(CssSelector.parse("rect.hot:hover").matches(rect, state))
        @Assert(CssSelector.parse("rect.hot:focus").matches(rect, state))
        @Assert(!CssSelector.parse("rect.cold:hover").matches(rect, state))
        @Assert(!CssSelector.parse(":not(:hover)").matches(rect, state))
        @Assert(CssSelector.parse(":not(:focus)").matches(rect, SvgInteractionState(hoveredIds: ["r"])))
    }
}
