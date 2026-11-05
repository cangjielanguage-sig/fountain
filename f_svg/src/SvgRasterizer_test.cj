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

internal func filledBitmap(
    size: Int64,
    pathText: String,
    rule: SvgFillRule,
    samples!: Int64 = 1,
    matrix!: SvgMatrix = SvgMatrix.identity
): SvgBitmap {
    let bitmap = SvgBitmap(size, size)
    let raster = SvgRasterizer(bitmap, samplesPerPixel: samples)
    raster.fill(SvgPathData.parse(pathText), matrix: matrix, color: SvgColor.Black, fillRule: rule)
    bitmap
}

@Test
public class SvgRasterizer_test {
    /** 4×4 矩形覆盖与半开半闭边界。 */
    @TestCase
    public func rectangleCoverage(): Unit {
        let inside = filledBitmap(4, "M0 0 L2 0 L2 2 L0 2 Z", SvgFillRule.Nonzero)
        @Assert(inside.pixel(0, 0) == SvgColor.Black)
        @Assert(inside.pixel(1, 1) == SvgColor.Black)
        @Assert(inside.pixel(2, 2).alpha == 0.0)
        @Assert(inside.pixel(3, 0).alpha == 0.0)

        let half = filledBitmap(4, "M0.5 0.5 L2.5 0.5 L2.5 2.5 L0.5 2.5 Z", SvgFillRule.Nonzero)
        @Assert(half.pixel(0, 0) == SvgColor.Black)
        @Assert(half.pixel(2, 0).alpha == 0.0)
        @Assert(half.pixel(1, 1) == SvgColor.Black)
    }

    /** 三角形、凹多边形与自交回旋体的 nonzero/evenodd 差异。 */
    @TestCase
    public func fillRules(): Unit {
        let triangleNonzero = filledBitmap(4, "M0 0 L4 0 L0 4 Z", SvgFillRule.Nonzero)
        let triangleEvenodd = filledBitmap(4, "M0 0 L4 0 L0 4 Z", SvgFillRule.Evenodd)
        @Assert(triangleNonzero.pixel(1, 1) == SvgColor.Black)
        @Assert(triangleEvenodd.pixel(1, 1) == SvgColor.Black)
        @Assert(triangleNonzero.pixel(3, 3).alpha == 0.0)

        let concaveText = "M0 0 L4 0 L4 1 L1 1 L1 4 L0 4 Z"
        let concave = filledBitmap(4, concaveText, SvgFillRule.Nonzero)
        @Assert(concave.pixel(2, 0) == SvgColor.Black)
        @Assert(concave.pixel(0, 2) == SvgColor.Black)
        @Assert(concave.pixel(2, 2).alpha == 0.0)

        let nestedText = "M0 0 L10 0 L10 10 L0 10 Z M3 3 L7 3 L7 7 L3 7 Z"
        let nestedNonzero = filledBitmap(10, nestedText, SvgFillRule.Nonzero)
        let nestedEvenodd = filledBitmap(10, nestedText, SvgFillRule.Evenodd)
        @Assert(nestedNonzero.pixel(5, 5) == SvgColor.Black)
        @Assert(nestedEvenodd.pixel(5, 5).alpha == 0.0)
        @Assert(nestedEvenodd.pixel(1, 5) == SvgColor.Black)
    }

    /** 水平边、重复点、顶点落在扫描线。 */
    @TestCase
    public func degenerateEdges(): Unit {
        let horizontal = filledBitmap(4, "M0 0 H4 H4 V4 H0 Z", SvgFillRule.Nonzero)
        @Assert(horizontal.pixel(0, 0) == SvgColor.Black)
        @Assert(horizontal.pixel(3, 3) == SvgColor.Black)

        let duplicate = filledBitmap(4, "M0 0 L0 0 L4 0 L4 4 Z", SvgFillRule.Nonzero)
        @Assert(duplicate.pixel(1, 1) == SvgColor.Black)

        let vertexOnScanline = filledBitmap(4, "M0 0 L4 0 L4 4 Z", SvgFillRule.Nonzero)
        @Assert(vertexOnScanline.pixel(2, 0) == SvgColor.Black)
        @Assert(vertexOnScanline.pixel(0, 3).alpha == 0.0)
    }

    /** 45° 斜边覆盖率：4×4 抗锯齿为中间值，1×1 只有 0/255。 */
    @TestCase
    public func antialiasing(): Unit {
        let smooth = filledBitmap(4, "M0 0 L4 4 L4 0 Z", SvgFillRule.Nonzero, samples: 4)
        let edge = smooth.pixel(0, 0)
        @Assert(edge.alpha > 0.0)
        @Assert(edge.alpha < 1.0)

        let hard = filledBitmap(4, "M0 0 L4 4 L4 0 Z", SvgFillRule.Nonzero, samples: 1)
        let hardEdge = hard.pixel(0, 0)
        @Assert(hardEdge.alpha == 0.0 || hardEdge.alpha == 1.0)
    }

    /** 预乘 over：背景、两层半透明、无暗边。 */
    @TestCase
    public func colorComposition(): Unit {
        let background = SvgBitmap(2, 2)
        background.fill(SvgColor.fromRgb(128, 128, 128))
        let raster = SvgRasterizer(background, samplesPerPixel: 1)
        raster.fill(
            SvgPathData.parse("M0 0 L2 0 L2 2 L0 2 Z"),
            color: SvgColor.fromRgb(255, 0, 0),
            opacity: 0.5
        )
        @Assert(colorNear(background.pixel(0, 0), SvgColor.fromRgb(191, 64, 64)))

        let transparent = SvgBitmap(1, 1)
        let raster2 = SvgRasterizer(transparent, samplesPerPixel: 1)
        raster2.fill(
            SvgPathData.parse("M0 0 L1 0 L1 1 L0 1 Z"),
            color: SvgColor.fromRgb(255, 0, 0),
            opacity: 0.5
        )
        let red = transparent.pixel(0, 0)
        @Assert(red.red == 255)
        @Assert(abs(red.alpha - 0.5) < 0.01)

        let layered = SvgBitmap(1, 1)
        let raster3 = SvgRasterizer(layered, samplesPerPixel: 1)
        raster3.fill(SvgPathData.parse("M0 0 L1 0 L1 1 L0 1 Z"), color: SvgColor.fromRgb(255, 0, 0), opacity: 0.5)
        raster3.fill(SvgPathData.parse("M0 0 L1 0 L1 1 L0 1 Z"), color: SvgColor.fromRgb(0, 0, 255), opacity: 0.5)
        @Assert(colorNear(layered.pixel(0, 0), SvgColor(85, 0, 170, alpha: 0.75), tolerance: 2))
    }

    /** 贝塞尔扁平化误差 ≤ 0.25 设备像素。 */
    @TestCase
    public func bezierFlattening(): Unit {
        let polyline = flattenCubicPolyline(
            SvgPoint(0.0, 0.0),
            SvgPoint(0.0, 10.0),
            SvgPoint(10.0, 10.0),
            SvgPoint(10.0, 0.0),
            0.25
        )
        @Assert(polyline.size >= 8)
        let dense = ArrayList<SvgPoint>()
        for (index in 0..1001) {
            let t = Float64(index) / 1000.0
            dense.add(cubicPointOnCurve(SvgPoint(0.0, 0.0), SvgPoint(0.0, 10.0), SvgPoint(10.0, 10.0), SvgPoint(10.0, 0.0), t))
        }
        for (index in 1..polyline.size) {
            let midX = (polyline[index - 1].x + polyline[index].x) / 2.0
            let midY = (polyline[index - 1].y + polyline[index].y) / 2.0
            var best = Float64.Inf
            for (point in dense) {
                let dx = point.x - midX
                let dy = point.y - midY
                let distance = sqrt(dx * dx + dy * dy)
                if (distance < best) {
                    best = distance
                }
            }
            @Assert(best <= 0.3)
        }
    }

    /** 设备矩阵先作用于控制点再扁平化。 */
    @TestCase
    public func deviceMatrix(): Unit {
        let scaled = filledBitmap(4, "M0 0 L1 0 L1 1 L0 1 Z", SvgFillRule.Nonzero, matrix: SvgMatrix.scale(2.0, 2.0))
        @Assert(scaled.pixel(0, 0) == SvgColor.Black)
        @Assert(scaled.pixel(1, 1) == SvgColor.Black)
        @Assert(scaled.pixel(2, 2).alpha == 0.0)
    }
}

internal func cubicPointOnCurve(p0: SvgPoint, p1: SvgPoint, p2: SvgPoint, p3: SvgPoint, t: Float64): SvgPoint {
    let mt = 1.0 - t
    let a = mt * mt * mt
    let b = 3.0 * mt * mt * t
    let c = 3.0 * mt * t * t
    let d = t * t * t
    SvgPoint(
        a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
}
