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

class M6TestFont <: SvgFont {
    let name: String

    init(name: String) {
        this.name = name
    }

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        Option<SvgPathData>.None
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        0.0
    }

    public func ascent(fontSize: Float64): Float64 {
        0.0
    }

    public func descent(fontSize: Float64): Float64 {
        0.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Option<SvgBounds>.None
    }
}

/** 带固定轮廓的测试字体：小写 `a`/`b`/`c` 有大写字形，`c` 故意缺少 `C`。 */
class M6CapsFont <: SvgFont {
    private static let GLYPH = "M0 0 L10 0 L10 10 L0 10 Z"

    private func supported(codePoint: Int64): Bool {
        codePoint == 65 || codePoint == 66 || codePoint == 97 || codePoint == 98 || codePoint == 99
    }

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        if (this.supported(codePoint)) {
            return Some(SvgPathData.parse(M6CapsFont.GLYPH))
        }
        Option<SvgPathData>.None
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        if (this.supported(codePoint)) {
            5.0
        } else {
            0.0
        }
    }

    public func ascent(fontSize: Float64): Float64 {
        8.0
    }

    public func descent(fontSize: Float64): Float64 {
        2.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Option<SvgBounds>.None
    }
}

/** 88 字节的最小 OS/2 表，仅填 `sxHeight`（偏移 86）。 */
private func m6Os2Table(sxHeight: Int64): Array<Byte> {
    let writer = M4ByteWriter()
    for (_ in 0..86) {
        writer.u8(0)
    }
    writer.i16(sxHeight)
    writer.toArray()
}

/** cmap format 12：`(startCode, endCode, startGlyph)` 三元组。 */
private func m6Cmap12(groups: Array<(Int64, Int64, Int64)>): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u16(0).u16(1).u16(3).u16(10).u32(12)
    writer.u16(12).u16(0).u32(16 + 12 * Int64(groups.size)).u32(0)
    writer.u32(Int64(groups.size))
    for ((start, end, glyph) in groups) {
        writer.u32(start).u32(end).u32(glyph)
    }
    writer.toArray()
}

private func m6TagName(index: Int64): String {
    let text = index.toString()
    if (text.size == 1) {
        return "f00" + text
    }
    if (text.size == 2) {
        return "f0" + text
    }
    "f" + text
}

private func m6FontName(font: ?SvgFont): String {
    match (font) {
        case Some(value) =>
            match (value) {
                case testFont: M6TestFont => testFont.name
                case _ => "other"
            }
        case None => "none"
    }
}

@Test
public class SvgFontDetailsM6_test {
    private func styleOf(attributes: String): (SvgComputedStyle, SvgStyleResolver) {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        (m5StyleOf(tree, document.elementById("r")), resolver)
    }

    /** 9 个关键字 + 百分比 + 非法值。 */
    @TestCase
    public func fontStretchParsing(): Unit {
        let cases: Array<(String, Float64)> = [
            ("ultra-condensed", 50.0), ("extra-condensed", 62.5), ("condensed", 75.0),
            ("semi-condensed", 87.5), ("normal", 100.0), ("semi-expanded", 112.5),
            ("expanded", 125.0), ("extra-expanded", 150.0), ("ultra-expanded", 200.0)
        ]
        for ((name, percent) in cases) {
            let value = SvgFontStretch.fromName(name) ?? throw invalidValue("missing")
            @Assert(value.percentage() == percent)
            @Assert(SvgFontStretch.fromName(name.toAsciiUpper()) == Some(value))
        }
        let custom = SvgFontStretch.fromName("80%") ?? throw invalidValue("missing")
        @Assert(custom.percentage() == 80.0)
        @Assert(custom.toString() == "80%")
        @Assert(SvgFontStretch.fromName("bogus").isNone())
        @Assert(SvgFontStretch.fromName("0%").isNone())
    }

    /** font-stretch 进入计算样式并可继承。 */
    @TestCase
    public func fontStretchStyle(): Unit {
        let (initial, _) = styleOf("")
        @Assert(initial.fontStretch() == SvgFontStretch.Normal)
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"p\" font-stretch=\"80%\">" +
            "<rect id=\"r\"/></g></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        @Assert(m5StyleOf(tree, document.elementById("r")).fontStretch().percentage() == 80.0)
    }

    /** 注册表 stretch 重载：精确、最近、回退。 */
    @TestCase
    public func registryStretch(): Unit {
        let registry = SvgFontRegistry()
        let narrow = M6TestFont("narrow")
        let wide = M6TestFont("wide")
        registry.register("Test", narrow, stretch: 80.0)
        registry.register("Test", wide, stretch: 120.0)
        @Assert(m6FontName(registry.resolve("Test", "normal", "normal", stretch: 80.0)) == "narrow")
        @Assert(m6FontName(registry.resolve("Test", "normal", "normal", stretch: 110.0)) == "wide")
        @Assert(m6FontName(registry.resolve("Test", "normal", "normal", stretch: 100.0)) == "narrow")
        @Assert(m6FontName(registry.resolve("Test", "normal", "normal", stretch: 90.0)) == "narrow")
        @Assert(m6FontName(registry.resolve("Test", "normal", "normal")) == "narrow")
    }

    /** font-feature-settings 解析与 64 条上限。 */
    @TestCase
    public func fontFeatureParsing(): Unit {
        let warnings = ArrayList<String>()
        let features = SvgFontFeatures.parse("\"liga\" 0, 'kern' 1, \"dlig\" on, \"hlig\" off", warnings)
        @Assert(!features.enabled("liga"))
        @Assert(features.enabled("kern"))
        @Assert(features.enabled("dlig"))
        @Assert(!features.enabled("hlig"))
        @Assert(warnings.size == 0)

        let many = ArrayList<String>()
        for (index in 0..70) {
            many.add("\"" + m6TagName(index) + "\" 1")
        }
        let limitedWarnings = ArrayList<String>()
        let limited = SvgFontFeatures.parse(joinTestStrings(many, ", "), limitedWarnings)
        @Assert(limited.size == 64)
        @Assert(limitedWarnings.size > 0)

        let bad = ArrayList<String>()
        SvgFontFeatures.parse("\"toolongtag\" 1, \"liga\" 5", bad)
        @Assert(bad.size >= 1)
    }

    /** 计算样式合并特性：font-feature-settings 覆盖 variant-ligatures，font-kerning 覆盖 kern。 */
    @TestCase
    public func featureMerge(): Unit {
        let (style, _) = styleOf(
            "font-variant-ligatures=\"none\" font-feature-settings=\"&quot;liga&quot; 1, &quot;kern&quot; 0\"" +
            " font-kerning=\"normal\""
        )
        let features = style.fontFeatures()
        @Assert(features.enabled("liga"))
        @Assert(features.enabled("kern"))

        let (kerningNone, _) = styleOf("font-kerning=\"none\"")
        @Assert(!kerningNone.fontFeatures().enabled("kern"))

        let (noneStyle, _) = styleOf("font-variant-ligatures=\"none\"")
        @Assert(!noneStyle.fontFeatures().enabled("liga"))
        @Assert(!noneStyle.fontFeatures().enabled("clig"))

        let (historical, _) = styleOf("font-variant-ligatures=\"historical-ligatures\"")
        @Assert(historical.fontFeatures().enabled("hlig"))
    }

    /** font-variant: small-caps 与 font-size-adjust 进入计算样式。 */
    @TestCase
    public func capsAndSizeAdjust(): Unit {
        let (style, _) = styleOf("font-variant=\"small-caps\" font-size-adjust=\"0.5\"")
        @Assert(style.fontVariantCaps() == "small-caps")
        @Assert(style.fontSizeAdjust() == Some(0.5))
        let (normal, resolver) = styleOf("font-variant=\"normal\" font-size-adjust=\"none\"")
        @Assert(normal.fontVariantCaps() == "normal")
        @Assert(normal.fontSizeAdjust().isNone())
        let (bad, badResolver) = styleOf("font-size-adjust=\"-1\"")
        @Assert(bad.fontSizeAdjust().isNone())
        var warned = false
        for (warning in badResolver.warnings) {
            if (warning.contains("font-size-adjust")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** text-decoration 长属性与简写展开。 */
    @TestCase
    public func decorationLonghands(): Unit {
        let (style, _) = styleOf(
            "text-decoration-line=\"underline line-through\" text-decoration-style=\"wavy\" " +
            "text-decoration-color=\"red\" text-decoration-thickness=\"2\" " +
            "text-underline-position=\"above\""
        )
        @Assert(style.textDecoration().underline)
        @Assert(style.textDecoration().lineThrough)
        @Assert(style.textDecorationStyle() == SvgTextDecorationStyle.Wavy)
        @Assert(style.textDecorationColor() == Some(SvgColor(255, 0, 0)))
        @Assert(style.textDecorationThickness() == Some(SvgLength(2.0)))
        @Assert(style.textUnderlinePosition() == SvgTextUnderlinePosition.Above)

        let (shorthand, _) = styleOf("text-decoration=\"underline dotted\"")
        @Assert(shorthand.textDecoration().underline)
        @Assert(shorthand.textDecorationStyle() == SvgTextDecorationStyle.Dotted)

        let (bad, resolver) = styleOf("text-decoration-style=\"triple\"")
        @Assert(bad.textDecorationStyle() == SvgTextDecorationStyle.Solid)
        var warned = false
        for (warning in resolver.warnings) {
            if (warning.contains("text-decoration-style")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 装饰线几何：double 两条线，dotted / dashed / wavy 生成更多片段。 */
    @TestCase
    public func decorationGeometry(): Unit {
        let solid = SvgTextDecorationSpec(
            lines: SvgTextDecoration(underline: true),
            style: SvgTextDecorationStyle.Solid
        )
        let double = SvgTextDecorationSpec(
            lines: SvgTextDecoration(underline: true),
            style: SvgTextDecorationStyle.Double
        )
        let dotted = SvgTextDecorationSpec(
            lines: SvgTextDecoration(underline: true),
            style: SvgTextDecorationStyle.Dotted
        )
        let dashed = SvgTextDecorationSpec(
            lines: SvgTextDecoration(underline: true),
            style: SvgTextDecorationStyle.Dashed
        )
        let wavy = SvgTextDecorationSpec(
            lines: SvgTextDecoration(underline: true),
            style: SvgTextDecorationStyle.Wavy
        )
        @Assert(solid.outline(width: 100.0, thickness: 2.0).commands.size <
            double.outline(width: 100.0, thickness: 2.0).commands.size)
        @Assert(solid.outline(width: 100.0, thickness: 2.0).commands.size <
            dotted.outline(width: 100.0, thickness: 2.0).commands.size)
        @Assert(solid.outline(width: 100.0, thickness: 2.0).commands.size <
            dashed.outline(width: 100.0, thickness: 2.0).commands.size)
        @Assert(solid.outline(width: 100.0, thickness: 2.0).commands.size <
            wavy.outline(width: 100.0, thickness: 2.0).commands.size)
    }

    /** pathLength 比例与非法值。 */
    @TestCase
    public func pathLengthRatio(): Unit {
        let path = SvgPath()
        path.setAttr("pathLength", "10")
        @Assert(SvgPathLength.ratio(path, 20.0) == 2.0)
        path.setAttr("pathLength", "40")
        @Assert(SvgPathLength.ratio(path, 20.0) == 0.5)
        path.removeAttr("pathLength")
        @Assert(SvgPathLength.ratio(path, 20.0) == 1.0)
        for (value in ["0", "-5", "nan", "bogus"]) {
            path.setAttr("pathLength", value)
            let warnings = ArrayList<String>()
            @Assert(SvgPathLength.ratio(path, 20.0, warnings) == 1.0)
            @Assert(warnings.size == 1)
        }
    }

    /** pathLength 影响 dasharray / dashoffset 渲染。 */
    @TestCase
    public func pathLengthDashRendering(): Unit {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"4\">" +
            "<line x1=\"0\" y1=\"2\" x2=\"40\" y2=\"2\" stroke=\"red\" stroke-width=\"2\" " +
            "stroke-dasharray=\"4 4\"/></svg>"
        let plain = SvgRenderer(options: SvgRenderOptions(width: 40, height: 4)).render(SvgParser.parse(svg))
        let scaled = SvgRenderer(options: SvgRenderOptions(width: 40, height: 4)).render(
            SvgParser.parse(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"4\">" +
                "<line x1=\"0\" y1=\"2\" x2=\"40\" y2=\"2\" stroke=\"red\" stroke-width=\"2\" " +
                "pathLength=\"20\" stroke-dasharray=\"4 4\"/></svg>"
            )
        )
        @Assert(plain.pixels != scaled.pixels)
        @Assert(scaled.pixel(1, 2).alpha == 1.0)
        @Assert(scaled.pixel(10, 2).alpha == 0.0)
    }

    /** textPath startOffset 绝对值按 pathLength 比例缩放，百分比保持实际弧长。 */
    @TestCase
    public func textPathPathLength(): Unit {
        let path = SvgPathData.parse("M0 0 L100 0")
        let layout = SvgTextPathLayout()
        let absolute = layout.place(
            [10.0],
            path,
            SvgLength(10.0),
            SvgTextAnchor.Start,
            pathLengthRatio: 2.0
        )
        @Assert(absolute[0].originX == 20.0)
        let percent = layout.place(
            [10.0],
            path,
            SvgLength(10.0, unit: SvgLengthUnit.Percent),
            SvgTextAnchor.Start,
            pathLengthRatio: 2.0
        )
        @Assert(percent[0].originX == 10.0)
    }

    private func textLayout(
        svg: String,
        registry: SvgFontRegistry
    ): (SvgTextRenderer, SvgTextLayout) {
        let document = SvgParser.parse(svg)
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        let renderer = SvgTextRenderer(registry: registry)
        (renderer, renderer.layout(text, style: style, root: Some(document.root), styles: tree))
    }

    private func glyphWidth(layout: SvgTextLayout): Float64 {
        let path = match (layout.glyphs[0].path) {
            case Some(value) => value
            case None => throw invalidValue("缺少字形轮廓")
        }
        match (pathDataBounds(path)) {
            case Some(value) => value.width
            case None => 0.0
        }
    }

    /** 5.3：仅 100% 字体 + `font-stretch: 80%` 时字形与 advance 水平缩放 0.8。 */
    @TestCase
    public func stretchSynthesisScalesGlyphAndAdvance(): Unit {
        let font = SvgTrueTypeFont.parse(m4BuildTtf())
        let registry = SvgFontRegistry()
        registry.register("M4", font)
        let (_, normal) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"M4\" font-size=\"10\">A</text></svg>",
            registry
        )
        let (_, stretched) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"M4\" font-size=\"10\" " +
            "font-stretch=\"80%\">A</text></svg>",
            registry
        )
        @Assert(abs(normal.advance - 6.0) < 1e-9)
        @Assert(abs(stretched.advance - 4.8) < 1e-9)
        @Assert(abs(this.glyphWidth(normal) - 1.0) < 1e-9)
        @Assert(abs(this.glyphWidth(stretched) - 0.8) < 1e-9)
    }

    /** 5.4：small-caps 使用大写字形并等比缩放 0.8，advance 同步。 */
    @TestCase
    public func smallCapsUsesUppercaseGlyph(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Caps", M6CapsFont())
        let (_, normal) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Caps\" font-size=\"10\">a</text></svg>",
            registry
        )
        let (_, caps) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Caps\" font-size=\"10\" " +
            "font-variant=\"small-caps\">a</text></svg>",
            registry
        )
        @Assert(abs(normal.advance - 5.0) < 1e-9)
        @Assert(abs(caps.advance - 4.0) < 1e-9)
        @Assert(abs(this.glyphWidth(normal) - 10.0) < 1e-9)
        @Assert(abs(this.glyphWidth(caps) - 8.0) < 1e-9)
    }

    /** 5.4：缺少大写字形时保留原字形并 warning。 */
    @TestCase
    public func smallCapsWarnsWhenUppercaseMissing(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Caps", M6CapsFont())
        let (renderer, layout) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Caps\" font-size=\"10\" " +
            "font-variant=\"small-caps\">c</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 5.0) < 1e-9)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("small-caps")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 5.5：OS/2 sxHeight 修正字号；缺表忽略并 warning，`none` 不改变输出。 */
    @TestCase
    public func sizeAdjustUsesXHeightRatio(): Unit {
        let registry = SvgFontRegistry()
        registry.register(
            "OS2",
            SvgTrueTypeFont.parse(m5BuildLayoutTtf([500, 600, 700, 800], os2: m6Os2Table(500)))
        )
        let (_, normal) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"OS2\" font-size=\"10\">A</text></svg>",
            registry
        )
        @Assert(abs(normal.advance - 6.0) < 1e-9)
        let (_, adjusted) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"OS2\" font-size=\"10\" " +
            "font-size-adjust=\"0.75\">A</text></svg>",
            registry
        )
        @Assert(abs(adjusted.advance - 9.0) < 1e-9)
        let (_, none) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"OS2\" font-size=\"10\" " +
            "font-size-adjust=\"none\">A</text></svg>",
            registry
        )
        @Assert(abs(none.advance - 6.0) < 1e-9)
    }

    /** 5.5：缺少 OS/2 时忽略 font-size-adjust 并 warning。 */
    @TestCase
    public func sizeAdjustWarnsWithoutOs2(): Unit {
        let registry = SvgFontRegistry()
        registry.register("NoOS2", SvgTrueTypeFont.parse(m5BuildLayoutTtf([500, 600, 700, 800])))
        let (renderer, layout) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"NoOS2\" font-size=\"10\" " +
            "font-size-adjust=\"0.75\">A</text></svg>",
            registry
        )
        @Assert(abs(layout.advance - 6.0) < 1e-9)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("font-size-adjust")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 逐字体处理 font-size-adjust：首个字体缺 OS/2 不影响后续字体。 */
    @TestCase
    public func sizeAdjustContinuesAfterMissingOs2(): Unit {
        let registry = SvgFontRegistry()
        registry.register("NoOS2", SvgTrueTypeFont.parse(m5BuildLayoutTtf([500, 600, 700, 800])))
        registry.register(
            "OS2",
            SvgTrueTypeFont.parse(m5BuildLayoutTtf([500, 600, 700, 800], os2: m6Os2Table(500)))
        )
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-size=\"10\" " +
            "font-size-adjust=\"0.75\"><tspan font-family=\"NoOS2\">A</tspan>" +
            "<tspan font-family=\"OS2\">A</tspan></text></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        let renderer = SvgTextRenderer(registry: registry)
        let layout = renderer.layout(text, style: style, root: Some(document.root), styles: tree)
        @Assert(abs(layout.advance - 15.0) < 1e-9)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("font-size-adjust")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 5.16：stretch + small-caps + size-adjust 叠加，textLength 在合成 advance 上计算。 */
    @TestCase
    public func combinedSynthesisAndTextLength(): Unit {
        let registry = SvgFontRegistry()
        registry.register(
            "Combo",
            SvgTrueTypeFont.parse(
                m5BuildLayoutTtf(
                    [500, 600, 700, 800],
                    cmap: m6Cmap12([(65, 66, 1), (97, 98, 1)]),
                    os2: m6Os2Table(500)
                )
            )
        )
        let (_, combined) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Combo\" font-size=\"10\" " +
            "font-stretch=\"80%\" font-variant=\"small-caps\" font-size-adjust=\"0.75\">a</text></svg>",
            registry
        )
        // 6.0 × 0.8（stretch）× 0.8（small-caps）× 1.5（size-adjust）。
        @Assert(abs(combined.advance - 5.76) < 1e-9)
        let (_, withLength) = textLayout(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Combo\" font-size=\"10\" " +
            "font-stretch=\"80%\" font-variant=\"small-caps\" font-size-adjust=\"0.75\" " +
            "textLength=\"20\" lengthAdjust=\"spacingAndGlyphs\">a</text></svg>",
            registry
        )
        @Assert(abs(withLength.advance - 20.0) < 1e-9)
        @Assert(abs(withLength.glyphs[0].advance - 20.0) < 1e-9)
    }

    /** 5.16：装饰线厚度按最终（tspan 覆盖后）字号计算。 */
    @TestCase
    public func decorationThicknessFollowsFinalFontSize(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Caps", M6CapsFont())
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text id=\"t\" font-family=\"Caps\" font-size=\"14\" " +
            "text-decoration=\"underline\"><tspan font-size=\"28\">a</tspan></text></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let element = document.elementsByTag("text")[0]
        let text = match (element) {
            case value: SvgTextElement => value
            case _ => throw invalidValue("不是文本元素")
        }
        let style = tree.get(element) ?? throw invalidValue("缺少文本样式")
        let renderer = SvgTextRenderer(registry: registry)
        let runs = renderer.decorationRuns(text, style: style, root: Some(document.root), styles: tree)
        @Assert(runs.size == 1)
        @Assert(abs(runs[0].bounds.height - 2.0) < 1e-9)
    }
}

private func joinTestStrings(items: ArrayList<String>, separator: String): String {
    let out = StringBuilder()
    for (index in 0..items.size) {
        if (index > 0) {
            out.append(separator)
        }
        out.append(items[index])
    }
    out.toString()
}
