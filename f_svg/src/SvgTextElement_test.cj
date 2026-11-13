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

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgTextElement_test {
    /** x/y/dx/dy 列表：单值存为单元素数组。 */
    @TestCase
    public func positionLists(): Unit {
        let text = SvgText()
        @Assert(text.tag == "text")
        text.x = [SvgLength(10.0), SvgLength(20.0), SvgLength(30.0)]
        text.y = [SvgLength(1.0)]
        text.dx = [SvgLength(2.0, unit: SvgLengthUnit.Px)]
        text.dy = [SvgLength(3.0, unit: SvgLengthUnit.Percent)]
        @Assert(text.attr("x") == Some("10,20,30"))
        @Assert(text.x.getOrThrow().size == 3)
        @Assert(text.x.getOrThrow()[1] == SvgLength(20.0))
        @Assert(text.y.getOrThrow().size == 1)
        @Assert(text.dx.getOrThrow()[0] == SvgLength(2.0, unit: SvgLengthUnit.Px))
        @Assert(text.dy.getOrThrow()[0] == SvgLength(3.0, unit: SvgLengthUnit.Percent))

        let parsed = SvgText()
        parsed.setAttr("x", "10")
        @Assert(parsed.x.getOrThrow().size == 1)
        @Assert(parsed.x.getOrThrow()[0] == SvgLength(10.0))
        parsed.setAttr("y", "10, 20 30")
        @Assert(parsed.y.getOrThrow().size == 3)
        parsed.setAttr("dx", "bad")
        @Assert(parsed.dx.isNone())
    }

    /** rotate 是数字列表。 */
    @TestCase
    public func rotateList(): Unit {
        let text = SvgText()
        text.rotate = [10.0, 20.0, -30.0]
        @Assert(text.attr("rotate") == Some("10,20,-30"))
        @Assert(text.rotate == Some([10.0, 20.0, -30.0]))
        text.setAttr("rotate", "45 90")
        @Assert(text.rotate == Some([45.0, 90.0]))
        text.setAttr("rotate", "x")
        @Assert(text.rotate.isNone())
        text.rotate = None
        @Assert(text.rotate.isNone())
    }

    /** 文本长度与对齐枚举。 */
    @TestCase
    public func layoutEnums(): Unit {
        let text = SvgText()
        text.textLength = SvgLength(100.0)
        text.lengthAdjust = SvgLengthAdjust.SpacingAndGlyphs
        text.textAnchor = SvgTextAnchor.Middle
        @Assert(text.attr("textLength") == Some("100"))
        @Assert(text.attr("lengthAdjust") == Some("spacingAndGlyphs"))
        @Assert(text.attr("text-anchor") == Some("middle"))
        @Assert(text.textLength == Some(SvgLength(100.0)))
        @Assert(text.lengthAdjust == Some(SvgLengthAdjust.SpacingAndGlyphs))
        @Assert(text.textAnchor == Some(SvgTextAnchor.Middle))

        text.setAttr("text-anchor", "end")
        @Assert(text.textAnchor == Some(SvgTextAnchor.End))
        text.setAttr("lengthAdjust", "spacing")
        @Assert(text.lengthAdjust == Some(SvgLengthAdjust.Spacing))
        text.setAttr("text-anchor", "nope")
        @Assert(text.textAnchor.isNone())
    }

    /** 字体属性。 */
    @TestCase
    public func fontProperties(): Unit {
        let text = SvgText()
        text.fontFamily = "serif"
        text.fontSize = SvgLength(12.0, unit: SvgLengthUnit.Px)
        text.fontWeight = "bold"
        text.fontStyle = "italic"
        text.letterSpacing = SvgLength(1.0)
        text.wordSpacing = SvgLength(2.0, unit: SvgLengthUnit.Em)
        @Assert(text.attr("font-family") == Some("serif"))
        @Assert(text.attr("font-size") == Some("12px"))
        @Assert(text.attr("font-weight") == Some("bold"))
        @Assert(text.attr("font-style") == Some("italic"))
        @Assert(text.attr("letter-spacing") == Some("1"))
        @Assert(text.attr("word-spacing") == Some("2em"))
        @Assert(text.fontFamily == Some("serif"))
        @Assert(text.fontSize == Some(SvgLength(12.0, unit: SvgLengthUnit.Px)))
        @Assert(text.fontWeight == Some("bold"))
        @Assert(text.fontStyle == Some("italic"))
        @Assert(text.letterSpacing == Some(SvgLength(1.0)))
        @Assert(text.wordSpacing == Some(SvgLength(2.0, unit: SvgLengthUnit.Em)))
    }

    /** 子类标签与文本内容。 */
    @TestCase
    public func subclassesAndText(): Unit {
        let text = SvgText()
        text.appendText("abc")
        let tspan = SvgTspan()
        tspan.appendText("def")
        text.appendElement(tspan)
        @Assert(tspan.tag == "tspan")
        @Assert(text.text() == "abcdef")
        @Assert(SvgTextPath().tag == "textPath")
    }
}

@Test
public class SvgTextPath_test {
    /** href 双写法读取，写侧默认 xlink:href。 */
    @TestCase
    public func href(): Unit {
        let bare = SvgTextPath()
        bare.setAttr("href", "#a")
        @Assert(bare.href == Some("#a"))

        let xlink = SvgTextPath()
        xlink.setAttr(SvgNamespaces.XLINK, "href", "#b")
        @Assert(xlink.href == Some("#b"))

        let written = SvgTextPath()
        written.href = "#c"
        @Assert(written.attr(SvgNamespaces.XLINK, "href") == Some("#c"))
        @Assert(written.attr("href").isNone())
        @Assert(written.href == Some("#c"))
    }

    /** startOffset。 */
    @TestCase
    public func startOffset(): Unit {
        let path = SvgTextPath()
        path.startOffset = SvgLength(50.0, unit: SvgLengthUnit.Percent)
        @Assert(path.attr("startOffset") == Some("50%"))
        @Assert(path.startOffset == Some(SvgLength(50.0, unit: SvgLengthUnit.Percent)))
        path.startOffset = None
        @Assert(path.startOffset.isNone())
    }
}
