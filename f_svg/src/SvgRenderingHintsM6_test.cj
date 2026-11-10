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
public class SvgRenderingHintsM6_test {
    private func styleOf(attributes: String): (SvgComputedStyle, SvgStyleResolver) {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        (m5StyleOf(tree, document.elementById("r")), resolver)
    }

    private func gradient(from: String, to: String): SvgLinearGradient {
        let gradient = SvgLinearGradient(
            x1: SvgLength(0.0),
            y1: SvgLength(0.0),
            x2: SvgLength(1.0),
            y2: SvgLength(0.0)
        )
        let first = SvgStop()
        first.offset = 0.0
        first.setAttr("stop-color", from)
        let second = SvgStop()
        second.offset = 1.0
        second.setAttr("stop-color", to)
        gradient.appendElement(first)
        gradient.appendElement(second)
        gradient
    }

    /** 四个属性的合法值、缺省与继承。 */
    @TestCase
    public func hintValues(): Unit {
        let (initial, _) = styleOf("")
        @Assert(initial.shapeRendering() == SvgShapeRendering.Auto)
        @Assert(initial.textRendering() == SvgTextRendering.Auto)
        @Assert(initial.colorRendering() == SvgColorRendering.Auto)
        @Assert(initial.colorInterpolation() == SvgColorInterpolation.Auto)

        let (explicit, _) = styleOf(
            "shape-rendering=\"geometricPrecision\" text-rendering=\"optimizeLegibility\" " +
            "color-rendering=\"optimizeQuality\" color-interpolation=\"linearRGB\""
        )
        @Assert(explicit.shapeRendering() == SvgShapeRendering.GeometricPrecision)
        @Assert(explicit.textRendering() == SvgTextRendering.OptimizeLegibility)
        @Assert(explicit.colorRendering() == SvgColorRendering.OptimizeQuality)
        @Assert(explicit.colorInterpolation() == SvgColorInterpolation.LinearRgb)

        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"p\" shape-rendering=\"crispEdges\">" +
            "<rect id=\"r\"/></g></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        @Assert(m5StyleOf(tree, document.elementById("r")).shapeRendering() == SvgShapeRendering.CrispEdges)
    }

    /** 非法值回退 auto 并 warning。 */
    @TestCase
    public func invalidHintsWarn(): Unit {
        let (style, resolver) = styleOf(
            "shape-rendering=\"fast\" text-rendering=\"pretty\" " +
            "color-rendering=\"nice\" color-interpolation=\"lab\""
        )
        @Assert(style.shapeRendering() == SvgShapeRendering.Auto)
        @Assert(style.textRendering() == SvgTextRendering.Auto)
        @Assert(style.colorRendering() == SvgColorRendering.Auto)
        @Assert(style.colorInterpolation() == SvgColorInterpolation.Auto)
        var count = 0
        for (warning in resolver.warnings) {
            if (warning.contains("rendering") || warning.contains("color-interpolation")) {
                count++
            }
        }
        @Assert(count == 4)
    }

    /** `optimizeSpeed` 关闭抗锯齿，覆盖率只剩 0 / 1。 */
    @TestCase
    public func shapeOptimizeSpeed(): Unit {
        let bitmap = SvgBitmap(16, 16)
        let path = SvgPathData.parse("M0 0 L15 8 L0 16 Z")
        let raster = SvgRasterizer(bitmap)
        raster.fill(
            path,
            color: SvgColor(255, 0, 0),
            antiAliasOverride: Some(false),
            toleranceScale: 1.0
        )
        for (y in 0..16) {
            for (x in 0..16) {
                let alpha = bitmap.pixel(x, y).alpha
                @Assert(alpha == 0.0 || alpha == 1.0)
            }
        }
    }

    /** 默认调用（无 hint）输出逐字节不变。 */
    @TestCase
    public func defaultRasterUnchanged(): Unit {
        let path = SvgPathData.parse("M0 0 L15 8 L0 16 Z")
        let first = SvgBitmap(16, 16)
        SvgRasterizer(first).fill(path, color: SvgColor(255, 0, 0))
        let second = SvgBitmap(16, 16)
        SvgRasterizer(second).fill(
            path,
            color: SvgColor(255, 0, 0),
            toleranceScale: 1.0,
            antiAliasOverride: Option<Bool>.None
        )
        @Assert(first.pixels == second.pixels)
    }

    /** `geometricPrecision` 容差缩小后覆盖更精确（与粗容差不同）。 */
    @TestCase
    public func geometricPrecisionChangesCoverage(): Unit {
        let path = SvgPathData.parse("M0 0 C0 14 14 14 14 0 Z")
        let coarse = SvgBitmap(16, 16)
        SvgRasterizer(coarse).fill(path, color: SvgColor(255, 0, 0), toleranceScale: 1.0)
        let precise = SvgBitmap(16, 16)
        SvgRasterizer(precise).fill(path, color: SvgColor(255, 0, 0), toleranceScale: 0.25)
        @Assert(coarse.pixels != precise.pixels)
    }

    /** `linearRGB` 红蓝中点为 sRGB ≈ (188,0,188)，端点不漂移。 */
    @TestCase
    public func linearRgbInterpolation(): Unit {
        let gradient = this.gradient("red", "blue")
        let box = SvgBounds(0.0, 0.0, 1.0, 1.0)
        let srgb = SvgGradientSampler()
        let middle = srgb.sample(gradient, SvgPoint(0.5, 0.5), box, SvgColor.Black)
        @Assert(middle.red == 128)
        @Assert(middle.blue == 128)

        let linear = SvgGradientSampler(colorInterpolation: "linearRGB")
        let linearMiddle = linear.sample(gradient, SvgPoint(0.5, 0.5), box, SvgColor.Black)
        @Assert(linearMiddle.red >= 186 && linearMiddle.red <= 190)
        @Assert(linearMiddle.blue >= 186 && linearMiddle.blue <= 190)
        @Assert(linearMiddle.green == 0)

        let start = linear.sample(gradient, SvgPoint(0.0, 0.5), box, SvgColor.Black)
        let end = linear.sample(gradient, SvgPoint(1.0, 0.5), box, SvgColor.Black)
        @Assert(start.toString() == "#ff0000")
        @Assert(end.toString() == "#0000ff")
    }

    /** `auto` / `sRGB` 输出与解析式一致。 */
    @TestCase
    public func srgbUnchanged(): Unit {
        let gradient = this.gradient("#102030", "#e0f0a0")
        let box = SvgBounds(0.0, 0.0, 1.0, 1.0)
        let auto = SvgGradientSampler()
        let srgb = SvgGradientSampler(colorInterpolation: "sRGB")
        for (step in 0..10) {
            let t = Float64(step) / 10.0
            let point = SvgPoint(t, 0.5)
            @Assert(auto.sample(gradient, point, box, SvgColor.Black).toString() ==
                srgb.sample(gradient, point, box, SvgColor.Black).toString())
        }
    }

    /** 量化级数改变中间色，端点保持不变。 */
    @TestCase
    public func colorRenderingQuantization(): Unit {
        let gradient = this.gradient("black", "white")
        let box = SvgBounds(0.0, 0.0, 1.0, 1.0)
        let precise = SvgGradientSampler(quantizeSteps: 512)
        let fast = SvgGradientSampler(quantizeSteps: 128)
        var differs = false
        for (step in 1..1001) {
            let t = Float64(step) / 1000.0
            let point = SvgPoint(t, 0.5)
            if (precise.sample(gradient, point, box, SvgColor.Black).toString() !=
                fast.sample(gradient, point, box, SvgColor.Black).toString()) {
                differs = true
            }
        }
        @Assert(differs)
        @Assert(precise.sample(gradient, SvgPoint(0.0, 0.5), box, SvgColor.Black).toString() == "#000000")
        @Assert(precise.sample(gradient, SvgPoint(1.0, 0.5), box, SvgColor.Black).toString() == "#ffffff")
    }

    /** 渲染管线读取 `shape-rendering`：optimizeSpeed 关闭边缘 AA。 */
    @TestCase
    public func shapeRenderingPipeline(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<path d=\"M0 0 L19 10 L0 20 Z\" fill=\"red\" shape-rendering=\"optimizeSpeed\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20)).render(document)
        var partial = false
        for (y in 0..20) {
            for (x in 0..20) {
                let alpha = bitmap.pixel(x, y).alpha
                if (alpha > 0.0 && alpha < 1.0) {
                    partial = true
                }
            }
        }
        @Assert(!partial)
    }

    /** 渲染管线读取 `color-interpolation`：linearRGB 渐变中点更亮。 */
    @TestCase
    public func linearRgbPipeline(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"21\" y2=\"0\" " +
            "gradientUnits=\"userSpaceOnUse\"><stop offset=\"0\" stop-color=\"red\"/>" +
            "<stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#g)\" color-interpolation=\"linearRGB\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20)).render(document)
        let middle = bitmap.pixel(10, 10)
        @Assert(middle.red >= 186 && middle.red <= 190)
        @Assert(middle.blue >= 186 && middle.blue <= 190)
    }

    /** 已声明非 sRGB profile 按 sRGB 渲染，warning 只记一次。 */
    @TestCase
    public func colorProfileRendering(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<style>@color-profile p { }</style>" +
            "<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"red\"/>" +
            "<stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs>" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#g)\" color-profile=\"p\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(width: 10, height: 10))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        var count = 0
        for (warning in renderer.warnings) {
            if (warning.contains("color-profile")) {
                count++
            }
        }
        @Assert(count == 1)
    }

    /** 四个提示同时声明时重复渲染逐字节一致。 */
    @TestCase
    public func combinedHintsStable(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\" shape-rendering=\"geometricPrecision\" " +
            "text-rendering=\"optimizeLegibility\" color-rendering=\"optimizeQuality\" " +
            "color-interpolation=\"sRGB\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(width: 10, height: 10))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(first.pixel(5, 5).toString() == "#ff0000")
    }

    /** `@color-profile` 解析与重复声明。 */
    @TestCase
    public func colorProfileParsing(): Unit {
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@color-profile p { src: url(profile.icc) }\n" +
            "@color-profile q { src: url(q.icc) }\n" +
            "@color-profile p { src: url(p2.icc) }\n" +
            "rect { fill: red }",
            warnings
        )
        @Assert(sheet.colorProfiles.size == 3)
        @Assert(sheet.colorProfiles[0].name == "p")
        @Assert(sheet.colorProfiles[0].src == Some("url(profile.icc)"))
        @Assert(sheet.colorProfiles[1].name == "q")
        @Assert(sheet.colorProfiles[2].src == Some("url(p2.icc)"))
        @Assert(sheet.rules.size == 1)

        let noSrc = CssStyleSheet.parse("@color-profile bare { }")
        @Assert(noSrc.colorProfiles.size == 1)
        @Assert(noSrc.colorProfiles[0].src.isNone())
    }

    /** 已声明 / 未声明的 `color-profile` 值。 */
    @TestCase
    public func colorProfileProperty(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "@color-profile p { }" +
            "rect { color-profile: p }" +
            "</style><rect id=\"r\"/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.colorProfile() == "p")

        let missing = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "rect { color-profile: nope }" +
            "</style><rect id=\"r\"/></svg>"
        )
        let secondResolver = SvgStyleResolver()
        let secondTree = secondResolver.compute(missing.root)
        let second = m5StyleOf(secondTree, missing.elementById("r"))
        @Assert(second.colorProfile() == "sRGB")
        var warned = false
        for (warning in secondResolver.warnings) {
            if (warning.contains("color-profile")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}
