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

/** 带大曲率轮廓的测试字体：容差变化会产生可观测的边缘差异。 */
class M6CurveFont <: SvgFont {
    private static let CURVE = "M10 80 C10 5 90 5 90 80 L90 90 L10 90 Z"

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        Some(SvgPathData.parse(M6CurveFont.CURVE))
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        100.0
    }

    public func ascent(fontSize: Float64): Float64 {
        80.0
    }

    public func descent(fontSize: Float64): Float64 {
        20.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Some(SvgBounds(10.0, 5.0, 80.0, 85.0))
    }
}

@Test
public class SvgTextToleranceM6_test {
    private func renderWith(hint: String): SvgBitmap {
        renderWith(hint, shape: "")
    }

    private func renderWith(hint: String, shape!: String): SvgBitmap {
        let registry = SvgFontRegistry()
        registry.register("Curve", M6CurveFont())
        let shapeAttr = if (shape.size == 0) {
            ""
        } else {
            " shape-rendering=\"" + shape + "\""
        }
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"120\">" +
            "<text x=\"5\" y=\"10\" font-family=\"Curve\" font-size=\"100\" fill=\"red\" " +
            "text-rendering=\"" + hint + "\"" + shapeAttr + ">A</text></svg>"
        )
        SvgRenderer(
            options: SvgRenderOptions(width: 120, height: 120, samplesPerPixel: 1, fonts: registry)
        ).render(document)
    }

    /** 四种 text-rendering 的扁平化容差倍率。 */
    @TestCase
    public func textToleranceFactors(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<text id=\"a\">A</text></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let text = document.elementsByTag("text")[0]
        for ((value, expected) in [
            ("auto", 1.0), ("optimizeSpeed", 2.0), ("optimizeLegibility", 0.5),
            ("geometricPrecision", 0.25)
        ]) {
            text.setAttr("text-rendering", value)
            let styles = SvgStyleResolver().compute(document.root)
            let style = styles.get(text) ?? throw invalidValue("缺少样式")
            @Assert(abs(svgTextTolerance(style) - expected) < 1e-9)
        }
        let initial = tree.get(text) ?? throw invalidValue("缺少样式")
        @Assert(abs(svgTextTolerance(initial) - 1.0) < 1e-9)
    }

    /** 四种 text-rendering 的扁平化容差影响实际像素。 */
    @TestCase
    public func textRenderingTolerance(): Unit {
        let auto = renderWith("auto")
        let speed = renderWith("optimizeSpeed")
        let precision = renderWith("geometricPrecision")
        @Assert(auto.pixels != speed.pixels)
        @Assert(auto.pixels != precision.pixels)
        @Assert(speed.pixels != precision.pixels)
    }

    /** 文本容差只由 `text-rendering` 决定，不受 `shape-rendering` 二次缩放。 */
    @TestCase
    public func textToleranceIndependentOfShapeRendering(): Unit {
        let plain = renderWith("optimizeSpeed")
        let withShape = renderWith("optimizeSpeed", shape: "geometricPrecision")
        @Assert(plain.pixels == withShape.pixels)
    }

    /** optimizeSpeed 关闭 Type 4 连字。 */
    @TestCase
    public func optimizeSpeedDisablesLigatures(): Unit {
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf(
                [500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 700],
                gsub: m5Gsub(3, [(10, [4])])
            )
        )
        let registry = SvgFontRegistry()
        registry.register("Test", font)
        let normal = this.layout("<text font-family=\"Test\" font-size=\"10\">fi</text>", registry)
        let speed = this.layout(
            "<text font-family=\"Test\" font-size=\"10\" text-rendering=\"optimizeSpeed\">fi</text>",
            registry
        )
        @Assert(normal.glyphs.size == 1)
        @Assert(speed.glyphs.size == 2)
    }

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
}
