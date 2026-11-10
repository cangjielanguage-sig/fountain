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

/** 解析文档并计算样式，返回根与样式树。 */
internal func m5ComputeStyles(svg: String): (SvgDocument, SvgComputedStyleTree, SvgStyleResolver) {
    let document = SvgParser.parse(svg)
    let resolver = SvgStyleResolver()
    let tree = resolver.compute(document.root)
    (document, tree, resolver)
}

internal func m5StyleOf(tree: SvgComputedStyleTree, element: ?SvgElement): SvgComputedStyle {
    match (element) {
        case Some(value) => tree.get(value) ?? throw invalidValue("元素没有计算样式")
        case None => throw invalidValue("元素不存在")
    }
}

@Test
public class CssSelectorCascadeM5_test {
    /** 属性选择器在真实级联中生效，压过呈现属性。 */
    @TestCase
    public func attributeSelectorCascades(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect[data-k] { fill: red }</style>" +
            "<g><rect id=\"r\" data-k=\"1\" fill=\"blue\"/></g></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fill().toString() == "#ff0000")
    }

    /** 结构伪类与兄弟组合器同时参与级联。 */
    @TestCase
    public func structuralAndSiblingCascade(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect:first-child { fill: green }" +
            "rect + circle { fill: orange }</style>" +
            "<g><rect id=\"r1\"/><circle id=\"c1\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r1")).fill().toString() == "#008000")
        @Assert(m5StyleOf(tree, document.elementById("c1")).fill().toString() == "#ffa500")
    }

    /** `:not()` 与属性选择器组合在级联中正确排除。 */
    @TestCase
    public func notInCascade(): Unit {
        let (document, tree) = m5CompleteNotStyles()
        @Assert(m5StyleOf(tree, document.elementById("skip")).fill().toString() != "#ff0000")
        @Assert(m5StyleOf(tree, document.elementById("plain")).fill().toString() == "#ff0000")
    }

    private func m5CompleteNotStyles(): (SvgDocument, SvgComputedStyleTree) {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect[data-k]:not(.skip) { fill: red }</style>" +
            "<g><rect id=\"skip\" class=\"skip\" data-k=\"1\"/><rect id=\"plain\" data-k=\"1\"/></g></svg>"
        )
        (document, tree)
    }

    /** 特异性决定胜出：类型 + 属性压过单个类。 */
    @TestCase
    public func specificityWins(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            ".a { fill: green } rect[data-k] { fill: red }</style>" +
            "<g><rect id=\"r\" class=\"a\" data-k=\"1\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#ff0000")
    }

    /** 同特异性按源顺序后者胜出。 */
    @TestCase
    public func sourceOrderWins(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "[data-k] { fill: green } .a { fill: red }</style>" +
            "<g><rect id=\"r\" class=\"a\" data-k=\"1\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#ff0000")
    }

    /** `!important` 压过内联普通值；内联普通值压过选择器。 */
    @TestCase
    public func importantInlineCompetition(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "#r { fill: red }</style>" +
            "<g><rect id=\"r\" style=\"fill: black !important\"/>" +
            "<rect id=\"s\" class=\"a\" fill=\"blue\" style=\"fill: black\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#000000")
        @Assert(m5StyleOf(tree, document.elementById("s")).fill().toString() == "#000000")
    }

    /** README 中的选择器示例必须可解析并匹配目标元素。 */
    @TestCase
    public func readmeExampleParses(): Unit {
        let selector = CssSelector.parse("g > rect:not(.skip)[data-role^=badge] + circle")
        let doc = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g>" +
            "<rect class=\"skip\" data-role=\"badge-1\"/>" +
            "<rect data-role=\"badge-2\"/><circle id=\"c\"/></g></svg>"
        )
        let circle = doc.elementById("c")
        @Assert(m5AttrSelectorMatches(selector.toString(), circle ?? SvgCircle()))
        @Assert(selector.toString() == "g > rect:not(.skip)[data-role^=badge] + circle")
    }

    /** 不支持的伪类只在 warnings 记一条，其他规则照常生效。 */
    @TestCase
    public func unsupportedPseudoWarnsOnce(): Unit {
        let (document, tree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect:active { fill: red } rect[data-k] { fill: green }</style>" +
            "<g><rect id=\"r\" data-k=\"1\"/></g></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("r")).fill().toString() == "#008000")
        var activeWarnings = 0
        for (warning in resolver.warnings) {
            if (warning.contains("active")) {
                activeWarnings++
            }
        }
        @Assert(activeWarnings == 1)
    }
}
