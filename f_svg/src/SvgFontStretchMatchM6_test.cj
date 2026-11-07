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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

/** 固定 advance 的测试字体，用于区分 stretch 面。 */
class M6StretchFont <: SvgFont {
    let amount: Float64

    init(amount: Float64) {
        this.amount = amount
    }

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        Some(SvgPathData.parse("M0 0 L" + formatSvgNumber(this.amount) + " 0 L" +
            formatSvgNumber(this.amount) + " 10 L0 10 Z"))
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        this.amount
    }

    public func ascent(fontSize: Float64): Float64 {
        8.0
    }

    public func descent(fontSize: Float64): Float64 {
        2.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Some(SvgBounds(0.0, 0.0, this.amount, 10.0))
    }
}

@Test
public class SvgFontStretchMatchM6_test {
    private func layout(stretch: String, registry: SvgFontRegistry): SvgTextLayout {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Stretch\" " +
            "font-size=\"10\" font-stretch=\"" + stretch + "\">A</text></svg>"
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

    /** 精确匹配 75% 字体时不再做合成缩放。 */
    @TestCase
    public func exactStretchMatchSkipsSynthesis(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Stretch", M6StretchFont(10.0), stretch: 100.0)
        registry.register("Stretch", M6StretchFont(8.0), stretch: 75.0)
        let normal = layout("normal", registry)
        @Assert(abs(normal.advance - 10.0) < 1e-9)
        let condensed = layout("75%", registry)
        @Assert(abs(condensed.advance - 8.0) < 1e-9)
    }

    /** 仅注册 100% 字体时保留百分比合成缩放。 */
    @TestCase
    public func synthesisWhenOnlyNormalFace(): Unit {
        let registry = SvgFontRegistry()
        registry.register("OnlyNormal", M6StretchFont(10.0))
        let condensed = layoutFor("OnlyNormal", "75%", registry)
        @Assert(abs(condensed.advance - 7.5) < 1e-9)
    }

    private func layoutFor(family: String, stretch: String, registry: SvgFontRegistry): SvgTextLayout {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"" + family +
            "\" font-size=\"10\" font-stretch=\"" + stretch + "\">A</text></svg>"
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
}
