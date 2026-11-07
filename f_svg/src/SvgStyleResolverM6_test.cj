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
public class SvgStyleResolverM6_test {
    private let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
        "rect { fill: blue }" +
        "rect:hover { fill: red }" +
        "rect:focus { stroke: green }" +
        "</style><rect id=\"r\"/></svg>"

    /** 交互规则在 compute 重载中参与级联。 */
    @TestCase
    public func computeWithInteraction(): Unit {
        let document = SvgParser.parse(this.svg)
        let state = SvgInteractionState(hoveredIds: ["r"], focusedIds: ["r"], root: document.root)
        let tree = SvgStyleResolver().compute(
            document.root,
            interaction: state,
            mediaWidth: 100.0,
            mediaHeight: 100.0
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fill().toString() == "#ff0000")
        @Assert(style.stroke().toString() == "#008000")
    }

    /** 未提供状态时交互规则不生效，普通规则照常。 */
    @TestCase
    public func withoutInteractionUnchanged(): Unit {
        let document = SvgParser.parse(this.svg)
        let tree = SvgStyleResolver().compute(document.root, mediaWidth: 100.0, mediaHeight: 100.0)
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fill().toString() == "#0000ff")
        @Assert(style.stroke().toString() == "none")
    }

    /** 同特异性时后出现的 :hover 规则胜出。 */
    @TestCase
    public func sameSpecificityLaterWins(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "*:hover { fill: red }" +
            "rect { fill: blue }" +
            "</style><rect id=\"r\"/></svg>"
        )
        let state = SvgInteractionState(hoveredIds: ["r"], root: document.root)
        let tree = SvgStyleResolver().compute(
            document.root,
            interaction: state,
            mediaWidth: 100.0,
            mediaHeight: 100.0
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#0000ff")
    }

    /** computeElement 重载同样接受交互状态。 */
    @TestCase
    public func computeElementWithInteraction(): Unit {
        let document = SvgParser.parse(this.svg)
        let rect = document.elementById("r") ?? throw invalidValue("missing")
        let sheet = CssStyleSheet.parse(
            "rect { fill: blue } rect:hover { fill: red }"
        )
        let resolver = SvgStyleResolver(sheet: sheet)
        let parent = resolver.computeElement(document.root, Option<SvgComputedStyle>.None)
        let state = SvgInteractionState(hoveredIds: ["r"], root: document.root)
        @Assert(sheet.rules.size == 2)
        @Assert(sheet.rules[1].selectors[0].matches(rect, state))
        let style = resolver.computeElement(
            rect,
            parent,
            interaction: state,
            mediaWidth: 100.0,
            mediaHeight: 100.0
        )
        @Assert(style.fill().toString() == "#ff0000")
    }

    /** 普通规则不受交互状态影响。 */
    @TestCase
    public func plainRulesUnaffected(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { fill: blue; stroke-width: 3 }" +
            "</style><rect id=\"r\"/></svg>"
        )
        let state = SvgInteractionState(hoveredIds: ["r"], focusedIds: ["r"], root: document.root)
        let tree = SvgStyleResolver().compute(
            document.root,
            interaction: state,
            mediaWidth: 100.0,
            mediaHeight: 100.0
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fill().toString() == "#0000ff")
        @Assert(style.strokeWidth().value == 3.0)
    }
}
