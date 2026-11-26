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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgDirectionM5_test {
    private func style(attributes: String): SvgComputedStyle {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text id=\"t\" " + attributes + ">abc</text></svg>"
        )
        m5StyleOf(tree, document.elementById("t"))
    }

    /** direction 继承、unicode-bidi 不继承。 */
    @TestCase
    public func inheritance(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g direction=\"rtl\" unicode-bidi=\"embed\">" +
            "<text id=\"t\">abc</text></g></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("t"))
        @Assert(style.direction() == SvgDirection.Rtl)
        @Assert(style.unicodeBidi() == SvgUnicodeBidi.Normal)
    }

    /** 三个枚举的解析与大小写。 */
    @TestCase
    public func enumParsing(): Unit {
        @Assert(SvgDirection.fromName("RTL") == Some(SvgDirection.Rtl))
        @Assert(SvgUnicodeBidi.fromName("bidi-override") == Some(SvgUnicodeBidi.BidiOverride))
        @Assert(SvgFontKerning.fromName("AUTO") == Some(SvgFontKerning.Auto))
        @Assert(SvgFontKerning.fromName("none") == Some(SvgFontKerning.None))
        @Assert(SvgFontKerning.fromName("always").isNone())
        @Assert(SvgFontKerning.Auto.toString() == "auto")
        @Assert(SvgFontKerning.Normal.toString() == "normal")
        @Assert(SvgFontKerning.None.toString() == "none")
    }

    /** RTL + bidi-override 反转视觉顺序。 */
    @TestCase
    public func visualReversal(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "unicode-bidi=\"bidi-override\" font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 3)
        @Assert(layout.glyphs[0].codePoint == 99)
        @Assert(layout.glyphs[1].codePoint == 98)
        @Assert(layout.glyphs[2].codePoint == 97)
    }

    /** RTL 下括号镜像。 */
    @TestCase
    public func bracketMirroring(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "font-family=\"Hershey\" font-size=\"10\">(a)</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 3)
        @Assert(layout.glyphs[2].codePoint == 0x29)
        @Assert(layout.glyphs[0].codePoint == 0x28)
    }

    /** LTR 纯拉丁文本不受影响。 */
    @TestCase
    public func ltrUnchanged(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"ltr\" " +
            "font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            registry
        )
        @Assert(layout.glyphs[0].codePoint == 97)
        @Assert(layout.glyphs[1].codePoint == 98)
        @Assert(layout.glyphs[2].codePoint == 99)
    }

    /** 竖排时不按行内双向重排。 */
    @TestCase
    public func verticalSkipsBidi(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "writing-mode=\"tb-rl\" font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 3)
        @Assert(layout.glyphs[0].codePoint == 97)
    }


    /** tspan 的 direction 参与行内重排。 */
    @TestCase
    public func tspanDirectionRtl(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"ltr\" " +
            "font-family=\"Hershey\" font-size=\"10\">ab<tspan direction=\"rtl\">cd</tspan></text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 4)
        @Assert(layout.glyphs[0].codePoint == 97)
        @Assert(layout.glyphs[1].codePoint == 98)
        @Assert(layout.glyphs[2].codePoint == 100)
        @Assert(layout.glyphs[3].codePoint == 99)
    }

    /** unicode-bidi: embed 建立与 direction 一致的嵌入层。 */
    @TestCase
    public func embedCreatesLayer(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"ltr\" " +
            "font-family=\"Hershey\" font-size=\"10\">ab" +
            "<tspan direction=\"rtl\" unicode-bidi=\"embed\">cd</tspan></text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 4)
        @Assert(layout.glyphs[2].codePoint == 100)
        @Assert(layout.glyphs[3].codePoint == 99)
    }

    /** `B` 类字符分段，段落顺序保持不变。 */
    @TestCase
    public func paragraphBreakSegmentsBidi(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "unicode-bidi=\"bidi-override\" " +
            "font-family=\"Hershey\" font-size=\"10\">ab\ncd</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 5)
        @Assert(layout.glyphs[0].codePoint == 98)
        @Assert(layout.glyphs[1].codePoint == 97)
        @Assert(layout.glyphs[2].codePoint == 10)
        @Assert(layout.glyphs[3].codePoint == 100)
        @Assert(layout.glyphs[4].codePoint == 99)
    }

    /** 竖排时 direction 决定列顺序。 */
    @TestCase
    public func verticalColumnOrderFollowsDirection(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let ltr = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"ltr\" " +
            "writing-mode=\"tb-rl\" x=\"10 10 20 20\" font-family=\"Hershey\" " +
            "font-size=\"10\">ABCD</text></svg>",
            registry
        )
        @Assert(abs(ltr.glyphs[0].x - 10.0) < 0.001)
        @Assert(abs(ltr.glyphs[2].x - 20.0) < 0.001)
        let rtl = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "writing-mode=\"tb-rl\" x=\"10 10 20 20\" font-family=\"Hershey\" " +
            "font-size=\"10\">ABCD</text></svg>",
            registry
        )
        @Assert(abs(rtl.glyphs[0].x - 20.0) < 0.001)
        @Assert(abs(rtl.glyphs[2].x - 10.0) < 0.001)
    }

    /** rotate 列表绑定逻辑字符，随 bidi 重排移动。 */
    @TestCase
    public func rotateFollowsLogicalCharacters(): Unit {
        let registry = SvgFontRegistry.defaultRegistry()
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text direction=\"rtl\" " +
            "rotate=\"10 20 30\" unicode-bidi=\"bidi-override\" " +
            "font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            registry
        )
        @Assert(layout.glyphs.size == 3)
        @Assert(abs(layout.glyphs[0].angle - 30.0) < 0.001)
        @Assert(abs(layout.glyphs[1].angle - 20.0) < 0.001)
        @Assert(abs(layout.glyphs[2].angle - 10.0) < 0.001)
    }

    /** direction 不改变元素几何。 */
    @TestCase
    public func directionDoesNotChangeGeometry(): Unit {
        let ltr = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text id=\"t\" direction=\"ltr\" " +
            "font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            "t"
        )
        let rtl = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text id=\"t\" direction=\"rtl\" " +
            "font-family=\"Hershey\" font-size=\"10\">abc</text></svg>",
            "t"
        )
        let left = ltr.getBBox() ?? throw invalidValue("缺少 ltr 包围盒")
        let right = rtl.getBBox() ?? throw invalidValue("缺少 rtl 包围盒")
        @Assert(abs(left.width - right.width) < 0.001)
        @Assert(abs(left.height - right.height) < 0.001)
    }

    /** 未声明 direction 时文本渲染与 M4 逐字节一致。 */
    @TestCase
    public func defaultsMatchM4(): Unit {
        m5RenderAndCompare("m4-text")
        m5RenderAndCompare("text")
    }
}
