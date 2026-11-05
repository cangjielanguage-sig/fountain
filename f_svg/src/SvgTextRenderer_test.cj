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

internal func textStyleOf(text: SvgTextElement): SvgComputedStyle {
    styleOf(computeTree(text), text)
}

internal func makeText(content: String, size!: Float64 = 10.0): SvgText {
    let text = SvgText()
    text.appendText(content)
    text.fontFamily = "Hershey"
    text.fontSize = SvgLength(size)
    text
}

@Test
public class SvgTextRenderer_test {
    /** 连续 advance、letter-spacing、word-spacing。 */
    @TestCase
    public func basicLayout(): Unit {
        let text = makeText("AB")
        let renderer = SvgTextRenderer()
        let layout = renderer.layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 2)
        @Assert(layout.glyphs[0].codePoint == 65)
        @Assert(layout.glyphs[1].codePoint == 66)
        @Assert(near(layout.glyphs[0].x, 0.0))
        @Assert(near(layout.glyphs[1].x, layout.glyphs[0].advance))
        @Assert(layout.bounds.isSome())

        text.letterSpacing = SvgLength(2.0)
        let spaced = renderer.layout(text, style: textStyleOf(text))
        @Assert(near(spaced.glyphs[1].x, spaced.glyphs[0].advance + 2.0))

        let words = makeText("A B")
        words.wordSpacing = SvgLength(3.0)
        let wordLayout = renderer.layout(words, style: textStyleOf(words))
        @Assert(wordLayout.glyphs.size == 3)
        let natural = wordLayout.glyphs[0].advance + wordLayout.glyphs[1].advance
        @Assert(near(wordLayout.glyphs[2].x, natural + 3.0))
    }

    /** text-anchor 三值、x/y 列表、dx/dy 列表、textLength 两模式。 */
    @TestCase
    public func positioning(): Unit {
        let renderer = SvgTextRenderer()
        let anchored = makeText("AB")
        anchored.textAnchor = SvgTextAnchor.Middle
        let middle = renderer.layout(anchored, style: textStyleOf(anchored))
        @Assert(near(middle.glyphs[0].x, -middle.advance / 2.0))

        anchored.textAnchor = SvgTextAnchor.End
        let end = renderer.layout(anchored, style: textStyleOf(anchored))
        @Assert(near(end.glyphs[0].x, -end.advance))

        let listed = makeText("AB")
        listed.x = [SvgLength(10.0), SvgLength(30.0)]
        listed.y = [SvgLength(5.0), SvgLength(6.0)]
        let listLayout = renderer.layout(listed, style: textStyleOf(listed))
        @Assert(near(listLayout.glyphs[0].x, 10.0))
        @Assert(near(listLayout.glyphs[1].x, 30.0))
        @Assert(near(listLayout.glyphs[0].y, 5.0))
        @Assert(near(listLayout.glyphs[1].y, 6.0))

        let single = makeText("AB")
        single.x = [SvgLength(7.0)]
        single.y = [SvgLength(9.0)]
        let singleLayout = renderer.layout(single, style: textStyleOf(single))
        @Assert(near(singleLayout.glyphs[0].x, 7.0))
        @Assert(near(singleLayout.glyphs[1].x, 7.0))
        @Assert(near(singleLayout.glyphs[0].y, 9.0))
        @Assert(near(singleLayout.glyphs[1].y, 9.0))

        let deltas = makeText("AB")
        deltas.dx = [SvgLength(1.0), SvgLength(2.0)]
        deltas.dy = [SvgLength(1.0), SvgLength(2.0)]
        let deltaLayout = renderer.layout(deltas, style: textStyleOf(deltas))
        @Assert(near(deltaLayout.glyphs[0].x, 1.0))
        @Assert(near(deltaLayout.glyphs[1].x, deltaLayout.glyphs[0].advance + 3.0))
        @Assert(near(deltaLayout.glyphs[1].y, 2.0))

        let fitted = makeText("AB")
        fitted.textLength = SvgLength(30.0)
        fitted.lengthAdjust = SvgLengthAdjust.Spacing
        let spacing = renderer.layout(fitted, style: textStyleOf(fitted))
        @Assert(near(spacing.glyphs[1].x + spacing.glyphs[1].advance, 30.0))

        fitted.lengthAdjust = SvgLengthAdjust.SpacingAndGlyphs
        let glyphs = renderer.layout(fitted, style: textStyleOf(fitted))
        @Assert(near(glyphs.glyphs[1].x + glyphs.glyphs[0].advance, 30.0))
        let naturalPath = renderer.layout(makeText("AB"), style: textStyleOf(makeText("AB")))
        let naturalWidth = pathWidth(naturalPath.glyphs[0].path ?? SvgPathData(Array<SvgPathCommand>()))
        let scaledWidth = pathWidth(glyphs.glyphs[0].path ?? SvgPathData(Array<SvgPathCommand>()))
        @Assert(scaledWidth > naturalWidth)
    }

    /** tspan 嵌套、字号覆盖与 dx/dy 累加。 */
    @TestCase
    public func tspans(): Unit {
        let text = makeText("A")
        let span = SvgTspan()
        span.fontSize = SvgLength(20.0)
        span.appendText("B")
        text.appendElement(span)
        text.appendText("C")
        let layout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 3)
        @Assert(near(layout.glyphs[1].fontSize, 20.0))
        @Assert(near(layout.glyphs[1].advance, layout.glyphs[0].advance * 2.0))
        @Assert(near(layout.glyphs[2].x, layout.glyphs[1].x + layout.glyphs[1].advance))

        let shifted = makeText("A")
        let shiftedSpan = SvgTspan()
        shiftedSpan.dx = [SvgLength(5.0)]
        shiftedSpan.dy = [SvgLength(2.0)]
        shiftedSpan.appendText("B")
        shifted.appendElement(shiftedSpan)
        shifted.appendText("C")
        let shiftedLayout = SvgTextRenderer().layout(shifted, style: textStyleOf(shifted))
        @Assert(near(shiftedLayout.glyphs[1].x, shiftedLayout.glyphs[0].advance + 5.0))
        @Assert(near(shiftedLayout.glyphs[1].y, 2.0))
        @Assert(near(shiftedLayout.glyphs[2].x, shiftedLayout.glyphs[1].x + shiftedLayout.glyphs[1].advance))
    }

    /** tspan 的 x/y 列表逐字符消费，短列表复用末值。 */
    @TestCase
    public func tspanPositionLists(): Unit {
        let text = makeText("A")
        let span = SvgTspan()
        span.x = [SvgLength(10.0), SvgLength(20.0)]
        span.y = [SvgLength(5.0)]
        span.appendText("ABC")
        text.appendElement(span)
        let layout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 4)
        @Assert(near(layout.glyphs[1].x, 10.0))
        @Assert(near(layout.glyphs[2].x, 20.0))
        @Assert(near(layout.glyphs[3].x, 20.0))
        @Assert(near(layout.glyphs[1].y, 5.0))
        @Assert(near(layout.glyphs[2].y, 5.0))
        @Assert(near(layout.glyphs[3].y, 5.0))
    }

    /** 缺字占位、无字体注册、textPath 降级与 rotate 忽略。 */
    @TestCase
    public func degradations(): Unit {
        let emptyRegistry = SvgTextRenderer(registry: SvgFontRegistry())
        let text = makeText("X")
        let missing = emptyRegistry.layout(text, style: textStyleOf(text))
        @Assert(missing.glyphs.size == 1)
        @Assert(missing.glyphs[0].path.isSome())
        @Assert(emptyRegistry.warnings.size >= 1)

        let pathText = SvgTextPath()
        pathText.fontFamily = "Hershey"
        pathText.fontSize = SvgLength(10.0)
        pathText.appendText("A")
        let pathRenderer = SvgTextRenderer()
        let pathLayout = pathRenderer.layout(pathText, style: textStyleOf(pathText))
        @Assert(pathLayout.glyphs.size == 1)
        @Assert(pathRenderer.warnings.size >= 1)

        let rotated = makeText("A")
        rotated.rotate = [15.0]
        let rotateRenderer = SvgTextRenderer()
        rotateRenderer.layout(rotated, style: textStyleOf(rotated))
        @Assert(rotateRenderer.warnings.size >= 1)
    }

    /** tspan 显式 x/y 不被外层 tspan 与根 text 覆盖。 */
    @TestCase
    public func explicitTspanPositionWins(): Unit {
        let renderer = SvgTextRenderer()

        let direct = makeText("")
        let directSpan = SvgTspan()
        directSpan.x = [SvgLength(50.0)]
        directSpan.y = [SvgLength(30.0)]
        directSpan.appendText("A")
        direct.appendElement(directSpan)
        direct.x = [SvgLength(0.0)]
        direct.y = [SvgLength(0.0)]
        let directLayout = renderer.layout(direct, style: textStyleOf(direct))
        @Assert(directLayout.glyphs.size == 1)
        @Assert(near(directLayout.glyphs[0].x, 50.0))
        @Assert(near(directLayout.glyphs[0].y, 30.0))

        let nested = makeText("")
        let outer = SvgTspan()
        outer.x = [SvgLength(50.0)]
        let inner = SvgTspan()
        inner.x = [SvgLength(80.0)]
        inner.appendText("A")
        outer.appendElement(inner)
        nested.appendElement(outer)
        nested.x = [SvgLength(0.0)]
        let nestedLayout = renderer.layout(nested, style: textStyleOf(nested))
        @Assert(nestedLayout.glyphs.size == 1)
        @Assert(near(nestedLayout.glyphs[0].x, 80.0))

        let plain = makeText("A")
        let plainSpan = SvgTspan()
        plainSpan.appendText("B")
        plain.appendElement(plainSpan)
        plain.x = [SvgLength(7.0)]
        let plainLayout = renderer.layout(plain, style: textStyleOf(plain))
        @Assert(plainLayout.glyphs.size == 2)
        @Assert(near(plainLayout.glyphs[0].x, 7.0))
        @Assert(near(plainLayout.glyphs[1].x, 7.0))
    }

    /** 文本轮廓接入光栅器。 */
    @TestCase
    public func rasterizedText(): Unit {
        let text = makeText("AB", size: 20.0)
        text.x = [SvgLength(2.0)]
        text.y = [SvgLength(20.0)]
        let style = textStyleOf(text)
        let renderer = SvgTextRenderer()
        let outline = renderer.outline(text, style: style) ?? SvgPathData(Array<SvgPathCommand>())
        let bitmap = SvgBitmap(40, 24)
        let raster = SvgRasterizer(bitmap, samplesPerPixel: 1)
        raster.fill(outline, color: SvgColor.Black, fillRule: SvgFillRule.Nonzero)
        var count = 0
        for (y in 0..bitmap.height) {
            for (x in 0..bitmap.width) {
                if (bitmap.pixel(x, y).alpha > 0.0) {
                    count++
                }
            }
        }
        @Assert(count > 10)

        let strokeBitmap = SvgBitmap(40, 24)
        SvgRasterizer(strokeBitmap, samplesPerPixel: 1).stroke(
            outline,
            color: SvgColor.Black,
            strokeWidth: 1.0
        )
        var strokeCount = 0
        for (y in 0..strokeBitmap.height) {
            for (x in 0..strokeBitmap.width) {
                if (strokeBitmap.pixel(x, y).alpha > 0.0) {
                    strokeCount++
                }
            }
        }
        @Assert(strokeCount > 0)

        let gradient = linearGradientForTest(0.0, 40.0)
        addStop(gradient, 0.0, SvgColor.fromRgb(255, 0, 0))
        addStop(gradient, 1.0, SvgColor.fromRgb(0, 0, 255))
        let gradientBitmap = SvgBitmap(40, 24)
        SvgRasterizer(gradientBitmap, samplesPerPixel: 1).fillGradient(
            outline,
            gradient,
            SvgBounds(0.0, 0.0, 40.0, 24.0),
            SvgColor.Black
        )
        var gradientCount = 0
        for (y in 0..gradientBitmap.height) {
            for (x in 0..gradientBitmap.width) {
                if (gradientBitmap.pixel(x, y).alpha > 0.0) {
                    gradientCount++
                }
            }
        }
        @Assert(gradientCount > 0)
    }
}

internal func pathWidth(path: SvgPathData): Float64 {
    match (pathDataBounds(path)) {
        case Some(box) => box.width
        case None => 0.0
    }
}
