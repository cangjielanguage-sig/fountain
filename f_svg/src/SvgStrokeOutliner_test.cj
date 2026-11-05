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

internal func strokeRaster(
    size: Int64,
    pathText: String,
    width: Float64,
    cap: SvgLineCap,
    join: SvgLineJoin,
    miter!: Float64 = 4.0,
    dash!: Array<Float64> = Array<Float64>(),
    dashOffset!: Float64 = 0.0
): SvgBitmap {
    let bitmap = SvgBitmap(size, size)
    let raster = SvgRasterizer(bitmap, samplesPerPixel: 4)
    raster.stroke(
        SvgPathData.parse(pathText),
        color: SvgColor.Black,
        strokeWidth: width,
        lineCap: cap,
        lineJoin: join,
        miterLimit: miter,
        dashArray: dash,
        dashOffset: dashOffset
    )
    bitmap
}

internal func contourBoundsOf(contours: Array<Array<SvgPoint>>): SvgBounds {
    var box = SvgBounds.empty()
    for (contour in contours) {
        for (point in contour) {
            box = box.union(SvgBounds(point.x, point.y, 0.0, 0.0))
        }
    }
    box
}

internal func alphaNear(first: SvgBitmap, second: SvgBitmap, tolerance!: Int64 = 2): Bool {
    if (first.width != second.width || first.height != second.height) {
        return false
    }
    for (y in 0..first.height) {
        for (x in 0..first.width) {
            let a = first.pixel(x, y)
            let b = second.pixel(x, y)
            let diff = abs(a.alpha - b.alpha) * 255.0
            if (diff > Float64(tolerance)) {
                return false
            }
            if (a.alpha > 0.0 && b.alpha > 0.0) {
                if (!colorNear(a, b, tolerance: tolerance)) {
                    return false
                }
            }
        }
    }
    true
}

@Test
public class SvgStrokeOutliner_test {
    /** butt / round / square 端点覆盖范围。 */
    @TestCase
    public func caps(): Unit {
        let butt = strokeRaster(16, "M2 2 L10 2", 4.0, SvgLineCap.Butt, SvgLineJoin.Miter)
        @Assert(butt.pixel(2, 2) == SvgColor.Black)
        @Assert(butt.pixel(1, 2).alpha == 0.0)
        @Assert(butt.pixel(0, 0).alpha == 0.0)

        let round = strokeRaster(16, "M2 2 L10 2", 4.0, SvgLineCap.Round, SvgLineJoin.Miter)
        @Assert(round.pixel(1, 2) == SvgColor.Black)
        @Assert(round.pixel(0, 0).alpha > 0.0)
        @Assert(round.pixel(0, 0).alpha < 1.0)

        let square = strokeRaster(16, "M2 2 L10 2", 4.0, SvgLineCap.Square, SvgLineJoin.Miter)
        @Assert(square.pixel(1, 2) == SvgColor.Black)
        @Assert(square.pixel(0, 0) == SvgColor.Black)
    }

    /** miter / 超限退 bevel / round / bevel。 */
    @TestCase
    public func joins(): Unit {
        let path = "M2 10 L10 10 L10 2"
        let miter = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Miter, miter: 4.0)
        @Assert(miter.pixel(13, 13).alpha > 0.0)

        let capped = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Miter, miter: 1.1)
        @Assert(capped.pixel(13, 13).alpha == 0.0)

        let bevel = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Bevel, miter: 4.0)
        @Assert(bevel.pixel(13, 13).alpha == 0.0)

        let round = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Round, miter: 4.0)
        @Assert(round.pixel(10, 11).alpha > 0.0)
        @Assert(round.pixel(13, 13).alpha == 0.0)
    }

    /** dash 周期、相位、奇数数组复制、全零与负值。 */
    @TestCase
    public func dashPatterns(): Unit {
        let points = [SvgPoint(0.0, 0.0), SvgPoint(13.0, 0.0)]
        let dashed = SvgStrokeOutliner.outlinePolyline(
            points,
            false,
            SvgStrokeStyle(2.0, dashArray: [4.0, 2.0])
        )
        @Assert(dashed.size == 3)

        let odd = SvgStrokeOutliner.outlinePolyline(
            points,
            false,
            SvgStrokeStyle(2.0, dashArray: [4.0])
        )
        @Assert(odd.size == 2)

        let phase = SvgStrokeOutliner.outlinePolyline(
            points,
            false,
            SvgStrokeStyle(2.0, dashArray: [4.0, 2.0], dashOffset: 2.0)
        )
        @Assert(phase.size == 3)
        let phaseBounds = contourBoundsOf(phase)
        @Assert(near(phaseBounds.x, 0.0))
        @Assert(phaseBounds.width > 7.9)

        let zeros = SvgStrokeOutliner.outlinePolyline(
            points,
            false,
            SvgStrokeStyle(2.0, dashArray: [0.0, 0.0])
        )
        @Assert(zeros.size == 0)

        let negative = SvgStrokeOutliner.outlinePolyline(
            points,
            false,
            SvgStrokeStyle(2.0, dashArray: [-1.0, 2.0])
        )
        @Assert(negative.size == 1)
    }

    /** 解析快速路径与通用 outliner 结果一致。 */
    @TestCase
    public func analyticFastPaths(): Unit {
        let style = SvgStrokeStyle(4.0, lineJoin: SvgLineJoin.Miter)
        let rect = SvgRect(
            x: SvgLength(8.0),
            y: SvgLength(8.0),
            width: SvgLength(16.0),
            height: SvgLength(16.0)
        )
        let analyticRect = SvgStrokeOutliner.outlineElement(rect, style) ?? Array<Array<SvgPoint>>()
        let genericRect = SvgStrokeOutliner.outlinePolyline(
            [SvgPoint(8.0, 8.0), SvgPoint(24.0, 8.0), SvgPoint(24.0, 24.0), SvgPoint(8.0, 24.0)],
            true,
            style
        )
        let bitmapAnalytic = SvgBitmap(32, 32)
        let bitmapGeneric = SvgBitmap(32, 32)
        SvgRasterizer(bitmapAnalytic, samplesPerPixel: 4).fillContours(
            analyticRect,
            SvgColor.Black,
            SvgFillRule.Nonzero,
            1.0
        )
        SvgRasterizer(bitmapGeneric, samplesPerPixel: 4).fillContours(
            genericRect,
            SvgColor.Black,
            SvgFillRule.Nonzero,
            1.0
        )
        @Assert(alphaNear(bitmapAnalytic, bitmapGeneric, tolerance: 3))

        let line = SvgLine(
            x1: SvgLength(2.0),
            y1: SvgLength(10.0),
            x2: SvgLength(28.0),
            y2: SvgLength(10.0)
        )
        let analyticLine = SvgStrokeOutliner.outlineElement(line, style) ?? Array<Array<SvgPoint>>()
        let genericLine = SvgStrokeOutliner.outlinePolyline(
            [SvgPoint(2.0, 10.0), SvgPoint(28.0, 10.0)],
            false,
            style
        )
        @Assert(
            boundsNear(contourBoundsOf(analyticLine), contourBoundsOf(genericLine))
        )

        let circle = SvgCircle(cx: SvgLength(16.0), cy: SvgLength(16.0), r: SvgLength(10.0))
        let analyticCircle = SvgStrokeOutliner.outlineElement(circle, style) ?? Array<Array<SvgPoint>>()
        let circlePoints = circlePolygonForStroke(16.0, 16.0, 10.0, 0.25)
        let genericCircle = SvgStrokeOutliner.outlinePolyline(circlePoints, true, style)
        let bitmapCircleAnalytic = SvgBitmap(32, 32)
        let bitmapCircleGeneric = SvgBitmap(32, 32)
        SvgRasterizer(bitmapCircleAnalytic, samplesPerPixel: 2).fillContours(
            analyticCircle,
            SvgColor.Black,
            SvgFillRule.Nonzero,
            1.0
        )
        SvgRasterizer(bitmapCircleGeneric, samplesPerPixel: 2).fillContours(
            genericCircle,
            SvgColor.Black,
            SvgFillRule.Nonzero,
            1.0
        )
        @Assert(boundsClose(contourBoundsOf(analyticCircle), contourBoundsOf(genericCircle), 0.75))
        let countA = filledPixelCount(bitmapCircleAnalytic)
        let countB = filledPixelCount(bitmapCircleGeneric)
        @Assert(abs(countA - countB) <= 20)
    }

    /** 零宽不绘制、轮廓按 nonzero 填充、自交不破洞。 */
    @TestCase
    public func strokeRasterization(): Unit {
        let zero = strokeRaster(16, "M2 2 L14 2", 0.0, SvgLineCap.Butt, SvgLineJoin.Miter)
        @Assert(zero.pixel(8, 2).alpha == 0.0)

        let normal = strokeRaster(16, "M2 2 L14 2", 4.0, SvgLineCap.Butt, SvgLineJoin.Miter)
        @Assert(normal.pixel(8, 2) == SvgColor.Black)
        @Assert(normal.pixel(8, 5).alpha == 0.0)

        let selfCross = strokeRaster(16, "M2 2 L14 14 L14 2 L2 14", 2.0, SvgLineCap.Butt, SvgLineJoin.Miter)
        @Assert(selfCross.pixel(8, 8) == SvgColor.Black)
    }
}

internal func boundsClose(actual: SvgBounds, expected: SvgBounds, tolerance: Float64): Bool {
    abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance &&
    abs(actual.width - expected.width) <= tolerance && abs(actual.height - expected.height) <= tolerance
}

internal func filledPixelCount(bitmap: SvgBitmap): Int64 {
    var count = 0
    for (y in 0..bitmap.height) {
        for (x in 0..bitmap.width) {
            if (bitmap.pixel(x, y).alpha > 0.5) {
                count++
            }
        }
    }
    count
}
