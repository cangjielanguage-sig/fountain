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

private func m4InkAt(bitmap: SvgBitmap, x: Int64, y: Int64): Bool {
    let color = bitmap.pixel(x, y)
    color.alpha > 0.2 && color.red > 150
}

@Test
public class SvgTextDecorationM4_test {
    /** 三条线的位置与厚度公式。 */
    @TestCase
    public func geometryFormulas(): Unit {
        @Assert(near(SvgTextDecorationGeometry.underlineOffset(20.0), 2.0))
        @Assert(near(SvgTextDecorationGeometry.overlineOffset(16.0), -16.0))
        @Assert(near(SvgTextDecorationGeometry.lineThroughOffset(16.0), -8.8))
        @Assert(near(SvgTextDecorationGeometry.thickness(20.0), 20.0 / 14.0))
        @Assert(SvgTextDecorationGeometry.thickness(5.0) == 1.0)
    }

    /** 组合装饰与 none。 */
    @TestCase
    public func decorationCombination(): Unit {
        let combined = SvgTextDecoration(underline: true, lineThrough: true)
        @Assert(combined.toString() == "underline line-through")
        @Assert(!combined.overline)
        @Assert(SvgTextDecoration.none.isNone())
    }

    /** 下划线 / 上划线 / 删除线的像素位置。 */
    @TestCase
    public func decorationPixels(): Unit {
        let underline = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="underline">A</text>',
            width: 30,
            height: 40
        )
        let underlineBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(underline)
        @Assert(m4InkAt(underlineBitmap, 5, 32))

        let overline = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="overline">A</text>',
            width: 30,
            height: 40
        )
        @Assert(m4InkAt(
            SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(overline), 5, 14))

        let through = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="line-through">A</text>',
            width: 30,
            height: 40
        )
        @Assert(m4InkAt(
            SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(through), 5, 21))

        let combined = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'text-decoration="underline line-through">A</text>',
            width: 30,
            height: 40
        )
        let combinedBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(combined)
        @Assert(m4InkAt(combinedBitmap, 5, 32))
        @Assert(m4InkAt(combinedBitmap, 5, 21))
    }

    /** 装饰线颜色取 fill。 */
    @TestCase
    public func decorationColor(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="blue" ' +
            'text-decoration="overline">A</text>',
            width: 30,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let color = bitmap.pixel(5, 14)
        @Assert(color.alpha > 0.2)
        @Assert(color.blue > 150 && color.red < 60)
    }

    /** 渐变装饰线按字形起点取样：每个字形重新从渐变起点开始。 */
    @TestCase
    public func decorationGradientPerGlyph(): Unit {
        let document = svgDoc(
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">' +
            '<stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/>' +
            '</linearGradient></defs>' +
            '<text y="30" font-family="Hershey" font-size="20" fill="url(#g)" ' +
            'text-decoration="underline">AA</text>',
            width: 40,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        // 第一个字形末端应接近渐变终点（蓝）。
        let firstEnd = bitmap.pixel(13, 32)
        @Assert(firstEnd.alpha > 0.2)
        @Assert(firstEnd.blue > 170 && firstEnd.red < 90)
        // 第二个字形按自身包围盒重新建立渐变，起点接近渐变起点（红）。
        var found = false
        var redStart = false
        for (y in 31..35) {
            for (x in 14..20) {
                let color = bitmap.pixel(x, y)
                if (color.alpha > 0.2) {
                    found = true
                    if (color.red > 170 && color.blue < 90) {
                        redStart = true
                    }
                }
            }
        }
        @Assert(found)
        @Assert(redStart)
    }

    /** 同一文本内 tspan 不断开。 */
    @TestCase
    public func tspanContinuity(): Unit {
        let text = makeText("AB", size: 20.0)
        text.setAttr("text-decoration", "underline")
        let outline = SvgTextRenderer().decorationOutline(text, style: textStyleOf(text))
        @Assert(outline.isSome())
        @Assert(outline.getOrThrow().commands.size == 10)
        let bounds = pathDataBounds(outline.getOrThrow())
        @Assert(bounds.isSome())
        @Assert(bounds.getOrThrow().width > 10.0)
    }

    /** 祖先的 `<style>` / 内联 `style` 声明同样向下传播。 */
    @TestCase
    public func ancestorStylePropagation(): Unit {
        let styled = svgDoc(
            '<style>g { text-decoration: underline }</style>' +
            '<g><text x="0" y="30" font-family="Hershey" font-size="20" fill="red">A</text></g>',
            width: 30,
            height: 40
        )
        let styledBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(styled)
        @Assert(m4InkAt(styledBitmap, 5, 32))

        let inlineStyled = svgDoc(
            '<g style="text-decoration: underline">' +
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red">A</text></g>',
            width: 30,
            height: 40
        )
        let inlineBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(inlineStyled)
        @Assert(m4InkAt(inlineBitmap, 5, 32))
    }

    /** tspan 内联 style 的 baseline-shift 生效。 */
    @TestCase
    public func tspanInlineBaselineShift(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red">' +
            'A<tspan x="20" style="baseline-shift: super">A</tspan></text>',
            width: 45,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        var firstTop: Int64 = -1
        var secondTop: Int64 = -1
        for (y in 0..bitmap.height) {
            for (x in 0..bitmap.width) {
                if (m4InkAt(bitmap, x, y)) {
                    if (x < 20 && firstTop < 0) {
                        firstTop = y
                    }
                    if (x >= 20 && secondTop < 0) {
                        secondTop = y
                    }
                }
            }
        }
        @Assert(firstTop >= 0 && secondTop >= 0)
        @Assert(secondTop <= firstTop - 5)
    }

    /** 祖先传播与显式 none 关闭。 */
    @TestCase
    public func ancestorPropagation(): Unit {
        let group = SvgContainer(SvgContainerKind.Group)
        group.setAttr("text-decoration", "underline")
        let text = makeText("A")
        group.appendElement(text)
        let outline = SvgTextRenderer().decorationOutline(text, style: textStyleOf(text))
        @Assert(outline.isSome())

        let disabled = makeText("A")
        disabled.setAttr("text-decoration", "none")
        let disabledOutline = SvgTextRenderer().decorationOutline(
            disabled,
            style: textStyleOf(disabled)
        )
        @Assert(disabledOutline.isNone())

        let parent = makeText("A")
        parent.setAttr("text-decoration", "underline")
        let span = SvgTspan()
        span.appendText("B")
        span.setAttr("text-decoration", "none")
        parent.appendElement(span)
        let layout = SvgTextRenderer().layout(parent, style: textStyleOf(parent))
        @Assert(layout.glyphs[0].decoration.underline)
        @Assert(layout.glyphs[1].decoration.isNone())
    }

    /** textPath 上装饰线随切线旋转。 */
    @TestCase
    public func textPathRotation(): Unit {
        let text = makeText("A", size: 20.0)
        text.setAttr("text-decoration", "underline")
        let path = SvgTextPath()
        path.setAttr("path", "M0 0 L 20 20")
        path.appendText("A")
        text.appendElement(path)
        let outline = SvgTextRenderer().decorationOutline(text, style: textStyleOf(text))
        @Assert(outline.isSome())
        let bounds = pathDataBounds(outline.getOrThrow())
        @Assert(bounds.isSome())
        @Assert(bounds.getOrThrow().height > 3.0)
        @Assert(bounds.getOrThrow().width > 3.0)
    }
}
