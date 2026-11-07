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

/** 固定 10 单位 advance 的测试字体。 */
class M6AdvanceFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        Some(SvgPathData.parse("M0 0 L8 0 L8 8 L0 8 Z"))
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        10.0
    }

    public func ascent(fontSize: Float64): Float64 {
        8.0
    }

    public func descent(fontSize: Float64): Float64 {
        2.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Some(SvgBounds(0.0, 0.0, 8.0, 8.0))
    }
}

@Test
public class SvgTextPathLengthM6_test {
    private func layout(body: String): SvgTextLayout {
        let registry = SvgFontRegistry()
        registry.register("Adv", M6AdvanceFont())
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<defs><path id=\"p\" d=\"M0 0 L100 0\"/></defs>" + body + "</svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        SvgTextRenderer(registry: registry).layout(
            text,
            style: style,
            root: Some(document.root),
            styles: tree
        )
    }

    /** 真实 textPath 调用按 pathLength 校准起点与字形弧长。 */
    @TestCase
    public func textPathPathLengthCalibratesLayout(): Unit {
        let body = "<text font-family=\"Adv\" font-size=\"10\">" +
            "<textPath href=\"#p\" pathLength=\"200\" startOffset=\"20\">AAAAAAAAAA</textPath></text>"
        let calibrated = layout(body)
        @Assert(calibrated.glyphs.size == 10)
        @Assert(abs(calibrated.glyphs[0].x - 10.0) < 1e-9)
        let plain = layout(
            "<text font-family=\"Adv\" font-size=\"10\">" +
            "<textPath href=\"#p\" startOffset=\"20\">AAAAAAAAAA</textPath></text>"
        )
        @Assert(plain.glyphs.size == 8)
        @Assert(abs(plain.glyphs[0].x - 20.0) < 1e-9)
    }
}
