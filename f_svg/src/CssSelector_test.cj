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

internal func selectorMatches(selector: String, element: SvgElement): Bool {
    CssSelector.parse(selector).matches(element)
}

internal func classedShape(tag: String, id: String, className: String): SvgElement {
    let element = match (SvgTag.create(tag)) {
        case Some(created) => created
        case None => SvgElement(tag)
    }
    element.setAttr("id", id)
    element.className = className
    element
}

@Test
public class CssSelector_test {
    /** 五类基本选择器与复合选择器。 */
    @TestCase
    public func basicSelectors(): Unit {
        let rect = classedShape("rect", "b", "a c")
        @Assert(selectorMatches("rect", rect))
        @Assert(selectorMatches(".a", rect))
        @Assert(selectorMatches(".c", rect))
        @Assert(!selectorMatches(".b", rect))
        @Assert(selectorMatches("#b", rect))
        @Assert(!selectorMatches("#a", rect))
        @Assert(selectorMatches("*", rect))
        @Assert(selectorMatches("rect.a#b", rect))
        @Assert(!selectorMatches("rect.b#b", rect))
        @Assert(!selectorMatches("circle", rect))
        @Assert(selectorMatches("rect.a.c", rect))
    }

    /** 后代、子代与三级链。 */
    @TestCase
    public func combinators(): Unit {
        let svg = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        group.className = "outer"
        let inner = SvgContainer(SvgContainerKind.Group)
        inner.className = "inner"
        let rect = classedShape("rect", "r", "leaf")
        inner.appendElement(rect)
        group.appendElement(inner)
        svg.appendElement(group)

        @Assert(selectorMatches("svg rect", rect))
        @Assert(selectorMatches("g rect", rect))
        @Assert(selectorMatches("g > g > rect", rect))
        @Assert(selectorMatches(".outer > .inner > .leaf", rect))
        @Assert(!selectorMatches("svg > rect", rect))
        @Assert(!selectorMatches(".outer > rect", rect))
        @Assert(selectorMatches(".inner rect", rect))
        @Assert(!selectorMatches(".other rect", rect))
        @Assert(!selectorMatches("g > circle", rect))

        let chain = CssSelector.parse("svg > g rect.a")
        @Assert(chain.parts.size == 3)
        @Assert(chain.parts[0].combinator.isNone())
        match (chain.parts[1].combinator) {
            case Some(value) => @Assert(value == CssCombinator.Child)
            case None => @Fail("第二个选择器部分应记录子代组合符")
        }
        match (chain.parts[2].combinator) {
            case Some(value) => @Assert(value == CssCombinator.Descendant)
            case None => @Fail("第三个选择器部分应记录后代组合符")
        }
    }

    /** 特异性累加与 `*` 不计。 */
    @TestCase
    public func specificity(): Unit {
        @Assert(CssSelector.parse("*").specificity == CssSpecificity(0, 0, 0))
        @Assert(CssSelector.parse("rect").specificity == CssSpecificity(0, 0, 1))
        @Assert(CssSelector.parse(".a").specificity == CssSpecificity(0, 1, 0))
        @Assert(CssSelector.parse("#b").specificity == CssSpecificity(1, 0, 0))
        @Assert(CssSelector.parse("rect.a#b").specificity == CssSpecificity(1, 1, 1))
        @Assert(CssSelector.parse("rect.a.b").specificity == CssSpecificity(0, 2, 1))
        @Assert(CssSelector.parse("g > rect.a").specificity == CssSpecificity(0, 1, 2))
        @Assert(CssSelector.parse("*#a").specificity == CssSpecificity(1, 0, 0))
        @Assert(CssSpecificity(1, 0, 0).compareTo(CssSpecificity(0, 9, 9)) > 0)
        @Assert(CssSpecificity(0, 2, 0).compareTo(CssSpecificity(0, 1, 9)) > 0)
        @Assert(CssSpecificity(0, 1, 2).compareTo(CssSpecificity(0, 1, 1)) > 0)
        @Assert(CssSpecificity(0, 1, 1).compareTo(CssSpecificity(0, 1, 1)) == 0)
    }

    /** 分组选择器取最高特异性。 */
    @TestCase
    public func groupTakesHighestSpecificity(): Unit {
        let sheet = CssStyleSheet.parse("rect, #a.b { fill: red }")
        @Assert(sheet.rules[0].specificity() == CssSpecificity(1, 1, 0))
        let equal = CssStyleSheet.parse("rect, circle { fill: red }")
        @Assert(equal.rules[0].specificity() == CssSpecificity(0, 0, 1))
    }

    /** 倒排桶先过滤再完整匹配，候选不丢规则。 */
    @TestCase
    public func selectorIndexFiltersCandidates(): Unit {
        let sheet = CssStyleSheet.parse("rect.a { fill: red } circle { fill: green } #x { fill: blue }")
        let index = CssSelectorIndex(sheet.rules)
        let element = classedShape("rect", "x", "a")
        let candidates = index.candidates(element)
        @Assert(candidates == [0, 2])
        let matched = ArrayList<Int64>()
        for (ruleIndex in candidates) {
            for (selector in sheet.rules[ruleIndex].selectors) {
                if (selector.matches(element)) {
                    matched.add(ruleIndex)
                    break
                }
            }
        }
        @Assert(matched.toArray() == [0, 2])
    }

    /** 空 class、重复 class、大小写与缺失属性。 */
    @TestCase
    public func edgeCases(): Unit {
        let plain = SvgRect()
        @Assert(!selectorMatches(".a", plain))
        @Assert(!selectorMatches("#a", plain))
        @Assert(selectorMatches("rect", plain))

        let duplicated = SvgRect()
        duplicated.className = "  a   a  "
        @Assert(selectorMatches(".a", duplicated))
        @Assert(selectorMatches(".a.a", duplicated))

        let upper = classedShape("rect", "X", "A")
        @Assert(!selectorMatches("RECT", upper))
        @Assert(!selectorMatches("#x", upper))
        @Assert(!selectorMatches(".a", upper))
        @Assert(selectorMatches("#X", upper))
        @Assert(selectorMatches(".A", upper))

        let emptyClass = SvgRect()
        emptyClass.className = ""
        @Assert(!selectorMatches(".a", emptyClass))

        var threw = false
        try {
            CssSelector.parse(".")
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
    }
}
