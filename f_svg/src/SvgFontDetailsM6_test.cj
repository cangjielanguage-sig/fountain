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
