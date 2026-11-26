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
public class SvgAnalyticLocalMode_test {
    /** 门限常量换算：8 MiB 对应 1,048,576 个 Float64。 */
    @TestCase
    public func thresholdConstants(): Unit {
        @Expect(ANALYTIC_LOCAL_ACCUMULATOR_BYTES, 8 * 1024 * 1024)
        @Expect(ANALYTIC_LOCAL_ACCUMULATOR_ELEMENTS, 1048576)
    }

    /** 门限判定：边界值取等号走 local，任一维非正或溢出都不走 local。 */
    @TestCase
    public func thresholdBoundaries(): Unit {
        @Expect(analyticUsesLocalAccumulator(512, 512), true)
        @Expect(analyticUsesLocalAccumulator(1024, 1024), true)
        @Expect(analyticUsesLocalAccumulator(2048, 512), true)
        @Expect(analyticUsesLocalAccumulator(1024, 1023), true)
        @Expect(analyticUsesLocalAccumulator(1, 1048576), true)
        @Expect(analyticUsesLocalAccumulator(1048576, 1), true)
        @Expect(analyticUsesLocalAccumulator(1024, 1025), false)
        @Expect(analyticUsesLocalAccumulator(2048, 2048), false)
        @Expect(analyticUsesLocalAccumulator(4096, 1024), false)
        @Expect(analyticUsesLocalAccumulator(2048, 2049), false)
        @Expect(analyticUsesLocalAccumulator(3840, 2160), false)
        @Expect(analyticUsesLocalAccumulator(1048576, 2), false)
        @Expect(analyticUsesLocalAccumulator(0, 100), false)
        @Expect(analyticUsesLocalAccumulator(100, 0), false)
        @Expect(analyticUsesLocalAccumulator(-1, 100), false)
        @Expect(analyticUsesLocalAccumulator(100, -1), false)
        @Expect(analyticUsesLocalAccumulator(Int64.Max, 2), false)
        @Expect(analyticUsesLocalAccumulator(Int64.Max, Int64.Max), false)
    }

    /** 512×512（门限以下）：local 与堆逐元素相等。 */
    @TestCase
    public func halfMegapixelTiersAgree(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 512 0 L 512 512 Z"),
            SvgMatrix.identity,
            0.25
        )
        assertTiersAgree(contours, 512, 512, SvgFillRule.Nonzero)
    }

    /** 1024×1024 恰好落在 8 MiB 门限：local 与堆逐元素相等。 */
    @TestCase
    public func megapixelTiersAgree(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 1024 0 L 1024 1024 Z"),
            SvgMatrix.identity,
            0.25
        )
        assertTiersAgree(contours, 1024, 1024, SvgFillRule.Nonzero)
    }

    /** 0 尺寸：返回空覆盖率，不因分档改变既有早退行为。 */
    @TestCase
    public func zeroSizeReturnsEmpty(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 4 0 L 4 4 Z"),
            SvgMatrix.identity,
            0.25
        )
        @Expect(analyticCoverage(contours, 0, 8, SvgFillRule.Nonzero).size, 0)
        @Expect(analyticCoverage(contours, 8, 0, SvgFillRule.Nonzero).size, 0)
    }

    /** 负尺寸：保持既有异常行为，不因分档新增静默路径。 */
    @TestCase
    public func negativeSizeKeepsException(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 4 0 L 4 4 Z"),
            SvgMatrix.identity,
            0.25
        )
        var thrown = false
        try {
            analyticCoverage(contours, -1, 8, SvgFillRule.Nonzero)
        } catch (e: Exception) {
            thrown = true
        }
        @Expect(thrown, true)
    }

    /** 三角形单轮廓：local 与堆逐元素相等。 */
    @TestCase
    public func triangleTiersAgree(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 4 0 L 4 4 Z"),
            SvgMatrix.identity,
            0.25
        )
        assertTiersAgree(contours, 4, 4, SvgFillRule.Nonzero)
    }

    /** 甜甜圈多轮廓 evenodd：local 与堆逐元素相等。 */
    @TestCase
    public func donutTiersAgree(): Unit {
        let path = localModeCirclePath(25.0, 25.0, 20.0) + " " +
            localModeCirclePath(25.0, 25.0, 10.0)
        let contours = flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25)
        assertTiersAgree(contours, 50, 50, SvgFillRule.Evenodd)
    }

    /** 自交五角星：nonzero 与 evenodd 两档均逐元素相等。 */
    @TestCase
    public func selfIntersectionTiersAgree(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 20 2 L 25 38 L 2 15 L 38 15 L 15 38 Z"),
            SvgMatrix.identity,
            0.25
        )
        assertTiersAgree(contours, 40, 40, SvgFillRule.Nonzero)
        assertTiersAgree(contours, 40, 40, SvgFillRule.Evenodd)
    }

    /** 分离多轮廓：local 与堆逐元素相等。 */
    @TestCase
    public func multipleContoursTiersAgree(): Unit {
        let path = localModeCirclePath(15.0, 25.0, 10.0) + " " +
            localModeCirclePath(40.0, 25.0, 10.0)
        let contours = flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25)
        assertTiersAgree(contours, 56, 40, SvgFillRule.Nonzero)
    }

    /** 早退几何（空轮廓、单点轮廓）两档一致且全零。 */
    @TestCase
    public func earlyExitTiersAgree(): Unit {
        let empty = Array<Array<SvgPoint>>(0, repeat: Array<SvgPoint>())
        assertTiersAgree(empty, 8, 8, SvgFillRule.Nonzero)

        let point = SvgPoint(1.0, 1.0)
        let single = Array<Array<SvgPoint>>(1, repeat: Array<SvgPoint>(1, repeat: point))
        assertTiersAgree(single, 8, 8, SvgFillRule.Nonzero)
    }

    /** 大画布冒烟：1024×1024 走 local、1024×1025 走堆，输出有效。 */
    @TestCase
    public func largeCanvasSmoke(): Unit {
        let contours = flattenPathData(
            SvgPathData.parse("M 0 0 L 8 0 L 8 8 Z"),
            SvgMatrix.identity,
            0.25
        )
        let localTier = analyticCoverageImpl(contours, 1024, 1024, SvgFillRule.Nonzero, true)
        @Expect(localTier.size, 1024 * 1024)
        @Expect(localTier[1 * 1024 + 1] > 0, true)
        @Expect(localTier[1023 * 1024 + 1023], 0)

        let heapTier = analyticCoverageImpl(contours, 1024, 1025, SvgFillRule.Nonzero, false)
        @Expect(heapTier.size, 1024 * 1025)
        @Expect(heapTier[1 * 1024 + 1] > 0, true)
        @Expect(heapTier[1024 * 1024 + 1023], 0)
    }
}

/** 对同一几何分别跑 local / 堆两档，逐元素比较。 */
private func assertTiersAgree(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule
): Unit {
    let localTier = analyticCoverageImpl(contours, width, height, fillRule, true)
    let heapTier = analyticCoverageImpl(contours, width, height, fillRule, false)
    @Expect(localTier.size, heapTier.size)
    var index = 0
    while (index < localTier.size) {
        if (localTier[index] != heapTier[index]) {
            @Fail("tier mismatch at ${index}: local=${localTier[index]} heap=${heapTier[index]}")
        }
        index++
    }
}

/** 用 180 边形近似圆，避免依赖 arc 扁平化细节；与既有测试辅助函数同构。 */
private func localModeCirclePath(
    cx: Float64,
    cy: Float64,
    radius: Float64,
    segments!: Int64 = 180
): String {
    let out = StringBuilder()
    let pi = 3.141592653589793
    for (index in 0..segments) {
        let angle = 2.0 * pi * Float64(index) / Float64(segments)
        let x = cx + radius * cos(angle)
        let y = cy + radius * sin(angle)
        if (index == 0) {
            out.append("M ${x} ${y}")
        } else {
            out.append(" L ${x} ${y}")
        }
    }
    out.append(" Z")
    out.toString()
}
