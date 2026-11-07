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

@Test
public class SvgFontFeatureApplyM6_test {
    private func layout(body: String, registry: SvgFontRegistry): SvgTextLayout {
        let document = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\">" + body + "</svg>")
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

    /** font-variant-ligatures: none 关闭普通 Type 4 liga。 */
    @TestCase
    public func ligaturesNoneDisablesLiga(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let normal = layout("<text font-family=\"Test\" font-size=\"10\">fi</text>", registry)
        @Assert(normal.glyphs.size == 1)
        let none = layout(
            "<text font-family=\"Test\" font-size=\"10\" font-variant-ligatures=\"none\">fi</text>",
            registry
        )
        @Assert(none.glyphs.size == 2)
    }

    /** font-feature-settings 的 "kern" 0 关闭字距。 */
    @TestCase
    public func featureKernZeroDisablesKerning(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf([500, 500, 500, 500, 500], kern: m5KernTable([(1, 2, -80)]))
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let normal = layout("<text font-family=\"Test\" font-size=\"10\">AV</text>", registry)
        @Assert(abs(normal.advance - 9.2) < 1e-9)
        let kernZero = layout(
            "<text font-family=\"Test\" font-size=\"10\" " +
            "font-feature-settings=\"&quot;kern&quot; 0\">AV</text>",
            registry
        )
        @Assert(abs(kernZero.advance - 10.0) < 1e-9)
    }

    /** 上下文连字 clig 默认开启，受 font-variant-ligatures 与特性设置控制。 */
    @TestCase
    public func contextualLigatureFeature(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5GsubTagged("clig", 3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let normal = layout("<text font-family=\"Test\" font-size=\"10\">fi</text>", registry)
        @Assert(normal.glyphs.size == 1)
        let none = layout(
            "<text font-family=\"Test\" font-size=\"10\" font-variant-ligatures=\"none\">fi</text>",
            registry
        )
        @Assert(none.glyphs.size == 2)
        let disabled = layout(
            "<text font-family=\"Test\" font-size=\"10\" " +
            "font-feature-settings=\"&quot;clig&quot; 0\">fi</text>",
            registry
        )
        @Assert(disabled.glyphs.size == 2)
    }

    /** 历史连字 hlig 需要显式开启。 */
    @TestCase
    public func historicalLigatureFeature(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5GsubTagged("hlig", 3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let normal = layout("<text font-family=\"Test\" font-size=\"10\">fi</text>", registry)
        @Assert(normal.glyphs.size == 2)
        let historical = layout(
            "<text font-family=\"Test\" font-size=\"10\" " +
            "font-variant-ligatures=\"historical-ligatures\">fi</text>",
            registry
        )
        @Assert(historical.glyphs.size == 1)
        let explicit = layout(
            "<text font-family=\"Test\" font-size=\"10\" " +
            "font-feature-settings=\"&quot;hlig&quot; 1\">fi</text>",
            registry
        )
        @Assert(explicit.glyphs.size == 1)
    }
}
