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

/** 90° 外角：两个线段的中心线在 `(10, 10)` 相交，`stroke-width` 为 8。 */
private let M6_RIGHT_ANGLE: Array<SvgPoint> = [
    SvgPoint(2.0, 10.0),
    SvgPoint(10.0, 10.0),
    SvgPoint(10.0, 2.0)
]

private func m6JoinContour(contours: Array<Array<SvgPoint>>): Array<SvgPoint> {
    // outlineOne 的顺序：两个线段四边形在前，连接轮廓其后。
    if (contours.size < 3) {
        return Array<SvgPoint>()
    }
    contours[2]
}

private func m6Distance(first: SvgPoint, second: SvgPoint): Float64 {
    let dx = first.x - second.x
    let dy = first.y - second.y
    sqrt(dx * dx + dy * dy)
}

@Test
public class SvgLineJoinM6_test {
    /** miter-clip 超限时在 miterlimit × stroke-width / 2 处垂直截断，不退化为 bevel。 */
    @TestCase
    public func miterClipTruncatesInsteadOfBevel(): Unit {
        let style = SvgStrokeStyle(8.0, lineJoin: SvgLineJoin.MiterClip, miterLimit: 1.1)
        let contours = SvgStrokeOutliner.outlineContours([M6_RIGHT_ANGLE], style)
        let join = m6JoinContour(contours)
        @Assert(join.size == 5)
        var clipped = 0
        for (point in join) {
            let distance = ((point.x - 10.0) + (point.y - 10.0)) / sqrt(2.0)
            if (abs(distance - 4.4) < 1e-9) {
                clipped++
            }
            @Assert(!(point.x > 13.0 && point.y > 13.0))
        }
        @Assert(clipped == 2)

        let bitmap = strokeRaster(20, "M2 10 L10 10 L10 2", 8.0, SvgLineCap.Butt, SvgLineJoin.MiterClip, miter: 1.1)
        // bevel 在 x+y=24 处收口，截断轮廓延伸到 x+y≈26.22，因此像素中心 (12.5,13.5) 只在 miter-clip 下被覆盖。
        @Assert(bitmap.pixel(12, 13).alpha > 0.0)
        @Assert(bitmap.pixel(14, 14).alpha == 0.0)
    }

    /** miterlimit 恰等于斜接比时保留完整尖角，略小则截断。 */
    @TestCase
    public func miterClipLimitBoundary(): Unit {
        let exact = sqrt(2.0)
        let full = SvgStrokeOutliner.outlineContours(
            [M6_RIGHT_ANGLE],
            SvgStrokeStyle(8.0, lineJoin: SvgLineJoin.MiterClip, miterLimit: exact)
        )
        @Assert(m6JoinContour(full).size == 4)

        let clipped = SvgStrokeOutliner.outlineContours(
            [M6_RIGHT_ANGLE],
            SvgStrokeStyle(8.0, lineJoin: SvgLineJoin.MiterClip, miterLimit: exact - 1e-6)
        )
        @Assert(m6JoinContour(clipped).size == 5)
    }

    /** arcs 以 stroke-width / 2 为半径生成圆弧连接，覆盖外角扇形。 */
    @TestCase
    public func arcsUsesHalfWidthRadius(): Unit {
        let width = 4.0
        let style = SvgStrokeStyle(width, lineJoin: SvgLineJoin.Arcs)
        let contours = SvgStrokeOutliner.outlineContours(
            [[SvgPoint(0.0, 0.0), SvgPoint(10.0, 0.0), SvgPoint(10.0, 10.0)]],
            style
        )
        let join = m6JoinContour(contours)
        @Assert(join.size >= 8)
        for (point in join) {
            @Assert(abs(m6Distance(point, SvgPoint(10.0, 0.0)) - width / 2.0) < 1e-9)
        }

        let bitmap = strokeRaster(20, "M0 10 L10 10 L10 20", width, SvgLineCap.Butt, SvgLineJoin.Arcs)
        // 半径 2：外角对角线 (11,9) 距顶点 1.414，在圆弧内；(12,8) 距顶点 2.828，在圆弧外。
        @Assert(bitmap.pixel(11, 9).alpha > 0.0)
        @Assert(bitmap.pixel(12, 8).alpha == 0.0)
    }

    /** arcs 与 round 的覆盖差异不超过 1/255。 */
    @TestCase
    public func arcsMatchesRoundCoverage(): Unit {
        let path = "M2 10 L10 10 L10 2"
        let arcs = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Arcs)
        let round = strokeRaster(20, path, 8.0, SvgLineCap.Butt, SvgLineJoin.Round)
        @Assert(alphaNear(arcs, round, tolerance: 1))
    }
}
