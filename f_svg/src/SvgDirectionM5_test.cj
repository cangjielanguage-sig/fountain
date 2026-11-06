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

    /** 未声明 direction 时文本渲染与 M4 逐字节一致。 */
    @TestCase
    public func defaultsMatchM4(): Unit {
        m5RenderAndCompare("m4-text")
        m5RenderAndCompare("text")
    }
}
