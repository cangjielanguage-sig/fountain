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

private let ANALYTIC_TRIANGLE: SvgPathData = SvgPathData.parse("M 0 0 L 4 0 L 4 4 Z")

@Test
public class SvgAnalyticRasterizer_test {
    /** 45° 斜线两侧相邻像素覆盖率和为 1（误差 ≤ 1/255）。 */
    @TestCase
    public func diagonalCoverageConservation(): Unit {
        let contours = flattenPathData(ANALYTIC_TRIANGLE, SvgMatrix.identity, 0.25)
        let coverage = analyticCoverage(contours, 4, 4, SvgFillRule.Nonzero)
        let left = Float64(coverage[0 * 4 + 0]) / 65535.0
        let right = Float64(coverage[1 * 4 + 1]) / 65535.0
        @Assert(abs(left + right - 1.0) <= 1.0 / 255.0)
        @Assert(abs(left - 0.5) <= 1.0 / 255.0)
        @Assert(abs(right - 0.5) <= 1.0 / 255.0)
    }

    /** 圆形解析覆盖率与 64× 参考图逐像素通道差 ≤ 2/255。 */
    @TestCase
    public func circleMatchesSupersampling(): Unit {
        let document = svgDoc(
            "<circle cx=\"25\" cy=\"25\" r=\"20\" fill=\"red\"/>",
            width: 50,
            height: 50
        )
        let analytic = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 4, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(document)
        let circle = (document.root.child("circle").getOrThrow() as SvgCircle).getOrThrow()
        let pathData = elementPathData(circle).getOrThrow()
        let reference = denseContourCoverage(
            flattenPathData(pathData, SvgMatrix.identity, 0.25),
            50,
            50,
            SvgFillRule.Nonzero
        )
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..reference.size) {
            let expected = Int64(round(reference[index] * 255.0))
            let actual = Int64(analytic.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail("worst=${worst} at ${worstIndex}")
        }
        @Assert(worst <= 2)
    }

    /** 高度小于 1/32 像素的细条也必须得到精确覆盖率。 */
    @TestCase
    public func thinFeatureCoverage(): Unit {
        let document = svgDoc(
            "<rect x=\"10\" y=\"10.005\" width=\"10\" height=\"0.01\" fill=\"red\"/>",
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(document)
        let coverage = bitmap.pixel(15, 10).alpha * 255.0
        @Assert(coverage >= 2.0 && coverage <= 4.0)
    }

    /** 自交路径 nonzero 实心、evenodd 空洞。 */
    @TestCase
    public func selfIntersectionRules(): Unit {
        let nonzero = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"M 15 1 L 27 35 L 1 13 L 29 13 L 3 35 Z\" fill=\"red\" fill-rule=\"nonzero\"/>",
                width: 40,
                height: 40
            )
        )
        @Assert(nonzero.pixel(15, 15).alpha > 0.5)

        let evenodd = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"M 15 1 L 27 35 L 1 13 L 29 13 L 3 35 Z\" fill=\"red\" fill-rule=\"evenodd\"/>",
                width: 40,
                height: 40
            )
        )
        @Assert(evenodd.pixel(15, 15).alpha < 0.1)
    }

    /** Analytic 档忽略 samplesPerPixel，输出逐字节一致。 */
    @TestCase
    public func samplesPerPixelIgnored(): Unit {
        let document = svgDoc(
            "<circle cx=\"20\" cy=\"20\" r=\"15\" fill=\"blue\"/>",
            width: 40,
            height: 40
        )
        let one = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(document)
        let four = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 4, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(document)
        @Assert(one.pixels == four.pixels)
    }

    /** 与图案、滤镜、marker、裁剪组合时输出确定。 */
    @TestCase
    public func combinedDeterminism(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><pattern id=\"p\" width=\"6\" height=\"6\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"6\" height=\"6\" fill=\"red\"/></pattern>" +
            "<filter id=\"f\"><feOffset dx=\"1\" dy=\"1\"/></filter>" +
            "<clipPath id=\"c\"><circle cx=\"20\" cy=\"20\" r=\"15\"/></clipPath>" +
            "<marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"blue\"/></marker></defs>" +
            "<g clip-path=\"url(#c)\" filter=\"url(#f)\">" +
            "<circle cx=\"20\" cy=\"20\" r=\"15\" fill=\"url(#p)\"/>" +
            "<path d=\"M 10 20 L 28 20\" fill=\"none\" stroke=\"black\" " +
            "marker-end=\"url(#m)\"/>" +
            "</g></svg>"
        )
        let options = SvgRenderOptions(samplesPerPixel: 4, antiAlias: SvgAntiAliasMode.Analytic)
        let first = SvgRenderer(options: options).render(document)
        let second = SvgRenderer(options: options).render(document)
        @Assert(first.pixels == second.pixels)
        var markerPixels = 0
        for (index in 0..first.pixels.size / 4) {
            if (first.pixels[index * 4] < 60 && first.pixels[index * 4 + 2] > 180 &&
                first.pixels[index * 4 + 3] > 0) {
                markerPixels++
            }
        }
        @Assert(markerPixels > 0)
    }
}


/** 用 180 边形近似圆，避免测试依赖 arc 扁平化细节。 */
private func polygonCirclePath(cx: Float64, cy: Float64, radius: Float64, segments!: Int64 = 180): String {
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

/** 独立的高密度参考覆盖率：每像素 128×128 点采样。 */
private func denseCircleCoverage(
    width: Int64,
    height: Int64,
    cx: Float64,
    cy: Float64,
    outer: Float64,
    inner: Float64
): Array<Float64> {
    let samples: Int64 = 128
    let result = Array<Float64>(width * height, repeat: 0.0)
    for (row in 0..height) {
        for (column in 0..width) {
            var inside = 0
            for (sy in 0..samples) {
                let y = Float64(row) + (Float64(sy) + 0.5) / Float64(samples)
                for (sx in 0..samples) {
                    let x = Float64(column) + (Float64(sx) + 0.5) / Float64(samples)
                    let distance = sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
                    if (distance <= outer && distance >= inner) {
                        inside++
                    }
                }
            }
            result[row * width + column] = Float64(inside) / Float64(samples * samples)
        }
    }
    result
}

private class SvgDenseCrossing {
    let x: Float64
    let direction: Int64

    init(x: Float64, direction: Int64) {
        this.x = x
        this.direction = direction
    }
}

private class SvgDenseSpan {
    let start: Float64
    let end: Float64

    init(start: Float64, end: Float64) {
        this.start = start
        this.end = end
    }
}

/**
 * 独立的 64× 参考图：每个像素取 64×64 个点，用扫描线交点与填充规则判定内外。
 *
 * 与解析覆盖率实现无共享代码：参考图只做点在多边形内判定，量化误差约 1/4096。
 */
private func denseContourCoverage(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule,
    samples!: Int64 = 64
): Array<Float64> {
    let result = Array<Float64>(width * height, repeat: 0.0)
    let sampleArea = Float64(samples * samples)
    let subRows = height * samples
    for (subRow in 0..subRows) {
        let row = subRow / samples
        let y = (Float64(subRow) + 0.5) / Float64(samples)
        let crossings = ArrayList<SvgDenseCrossing>()
        for (contour in contours) {
            if (contour.size < 2) {
                continue
            }
            var index = 0
            while (index < contour.size) {
                let first = contour[index]
                let second = contour[(index + 1) % contour.size]
                if (first.y != second.y) {
                    let low = if (first.y < second.y) { first.y } else { second.y }
                    let high = if (first.y < second.y) { second.y } else { first.y }
                    if (y >= low && y < high) {
                        let fraction = (y - first.y) / (second.y - first.y)
                        crossings.add(
                            SvgDenseCrossing(
                                first.x + (second.x - first.x) * fraction,
                                if (second.y > first.y) { 1 } else { -1 }
                            )
                        )
                    }
                }
                index++
            }
        }
        if (crossings.size < 2) {
            continue
        }
        sortDenseCrossings(crossings)
        let spans = ArrayList<SvgDenseSpan>()
        match (fillRule) {
            case Nonzero =>
                var winding: Int64 = 0
                var index = 0
                while (index + 1 < crossings.size) {
                    winding += crossings[index].direction
                    if (winding != 0) {
                        spans.add(SvgDenseSpan(crossings[index].x, crossings[index + 1].x))
                    }
                    index++
                }
            case Evenodd =>
                var index = 0
                while (index + 1 < crossings.size) {
                    spans.add(SvgDenseSpan(crossings[index].x, crossings[index + 1].x))
                    index += 2
                }
        }
        for (span in spans) {
            if (span.end <= span.start) {
                continue
            }
            var column = Int64(floor(span.start))
            if (column < 0) {
                column = 0
            }
            let last = Int64(ceil(span.end)) - 1
            while (column <= last && column < width) {
                var inside = 0
                for (subColumn in 0..samples) {
                    let x = Float64(column) + (Float64(subColumn) + 0.5) / Float64(samples)
                    if (x >= span.start && x < span.end) {
                        inside++
                    }
                }
                if (inside > 0) {
                    result[row * width + column] += Float64(inside) / sampleArea
                }
                column++
            }
        }
    }
    result
}

private func sortDenseCrossings(values: ArrayList<SvgDenseCrossing>): Unit {
    var index = 1
    while (index < values.size) {
        let value = values[index]
        var position = index - 1
        while (position >= 0 && values[position].x > value.x) {
            values[position + 1] = values[position]
            position--
        }
        values[position + 1] = value
        index++
    }
}

@Test
public class SvgAnalyticComplexM3_test {
    /** 甜甜圈（多轮廓 evenodd）逐像素误差 ≤ 2/255。 */
    @TestCase
    public func donutMatchesDenseReference(): Unit {
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"" + polygonCirclePath(25.0, 25.0, 20.0) + " " +
                polygonCirclePath(25.0, 25.0, 10.0) + "\" " +
                "fill=\"red\" fill-rule=\"evenodd\"/>",
                width: 50,
                height: 50
            )
        )
        let reference = denseCircleCoverage(50, 50, 25.0, 25.0, 20.0, 10.0)
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..reference.size) {
            let expected = Int64(round(reference[index] * 255.0))
            let actual = Int64(bitmap.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail("worst=${worst} at ${worstIndex}")
        }
        @Assert(worst <= 2)
        @Assert(bitmap.pixel(25, 25).alpha == 0.0)
    }

    /** 甜甜圈按同一扁平化几何的 64× 参考图逐像素比较，最大通道差 ≤ 2/255。 */
    @TestCase
    public func donutMatchesContourReference(): Unit {
        let path = polygonCirclePath(25.0, 25.0, 20.0) + " " + polygonCirclePath(25.0, 25.0, 10.0)
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"${path}\" fill=\"red\" fill-rule=\"evenodd\"/>",
                width: 50,
                height: 50
            )
        )
        let reference = denseContourCoverage(
            flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25),
            50,
            50,
            SvgFillRule.Evenodd
        )
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..reference.size) {
            let expected = Int64(round(reference[index] * 255.0))
            let actual = Int64(bitmap.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail(
                "甜甜圈 worst=${worst} at row=${worstIndex / 50} column=${worstIndex % 50}"
            )
        }
        @Assert(worst <= 2)
    }

    /** 两个分离轮廓与高密度参考逐像素一致。 */
    @TestCase
    public func multipleContoursMatchReference(): Unit {
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"" + polygonCirclePath(15.0, 25.0, 10.0) + " " +
                polygonCirclePath(40.0, 25.0, 10.0) + "\" " +
                "fill=\"red\" fill-rule=\"nonzero\"/>",
                width: 56,
                height: 40
            )
        )
        let left = denseCircleCoverage(56, 40, 15.0, 25.0, 10.0, 0.0)
        let right = denseCircleCoverage(56, 40, 40.0, 25.0, 10.0, 0.0)
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..left.size) {
            let reference = if (left[index] > right[index]) { left[index] } else { right[index] }
            let expected = Int64(round(reference * 255.0))
            let actual = Int64(bitmap.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail("worst=${worst} at ${worstIndex}")
        }
        @Assert(worst <= 2)
    }

    /** 自交五角星：nonzero 填充面积大于 evenodd。 */
    @TestCase
    public func selfIntersectionAreaDiffers(): Unit {
        let path = "M 20 2 L 25 38 L 2 15 L 38 15 L 15 38 Z"
        let nonzero = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(svgDoc("<path d=\"${path}\" fill=\"red\" fill-rule=\"nonzero\"/>", width: 40, height: 40))
        let evenodd = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(svgDoc("<path d=\"${path}\" fill=\"red\" fill-rule=\"evenodd\"/>", width: 40, height: 40))
        var nonzeroArea: Int64 = 0
        var evenoddArea: Int64 = 0
        for (index in 0..nonzero.pixels.size / 4) {
            nonzeroArea += Int64(nonzero.pixels[index * 4 + 3])
            evenoddArea += Int64(evenodd.pixels[index * 4 + 3])
        }
        @Assert(nonzeroArea > evenoddArea)
        @Assert(evenoddArea > 0)
        let contours = flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25)
        let referenceNonzero = denseContourCoverage(contours, 40, 40, SvgFillRule.Nonzero)
        let referenceEvenodd = denseContourCoverage(contours, 40, 40, SvgFillRule.Evenodd)
        var expectedNonzero: Float64 = 0.0
        var expectedEvenodd: Float64 = 0.0
        for (index in 0..referenceNonzero.size) {
            expectedNonzero += referenceNonzero[index]
            expectedEvenodd += referenceEvenodd[index]
        }
        // 64× 参考图自身的总面积量化误差约 1 px²；再留 2 px² 余量。
        @Assert(abs(Float64(nonzeroArea) / 255.0 - expectedNonzero) <= 3.0)
        @Assert(abs(Float64(evenoddArea) / 255.0 - expectedEvenodd) <= 3.0)
    }

    /** 自交五角星 nonzero 与 64× 参考图逐像素比较，最大通道差 ≤ 2/255。 */
    @TestCase
    public func selfIntersectionNonzeroMatchesDenseReference(): Unit {
        let path = "M 20 2 L 25 38 L 2 15 L 38 15 L 15 38 Z"
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"${path}\" fill=\"red\" fill-rule=\"nonzero\"/>",
                width: 40,
                height: 40
            )
        )
        let reference = denseContourCoverage(
            flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25),
            40,
            40,
            SvgFillRule.Nonzero
        )
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..reference.size) {
            let expected = Int64(round(reference[index] * 255.0))
            let actual = Int64(bitmap.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail("nonzero 五角星 worst=${worst} at row=${worstIndex / 40} column=${worstIndex % 40}")
        }
        @Assert(worst <= 2)
    }

    /** 自交五角星 evenodd 与 64× 参考图逐像素比较，最大通道差 ≤ 2/255。 */
    @TestCase
    public func selfIntersectionEvenoddMatchesDenseReference(): Unit {
        let path = "M 20 2 L 25 38 L 2 15 L 38 15 L 15 38 Z"
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(
            svgDoc(
                "<path d=\"${path}\" fill=\"red\" fill-rule=\"evenodd\"/>",
                width: 40,
                height: 40
            )
        )
        let reference = denseContourCoverage(
            flattenPathData(SvgPathData.parse(path), SvgMatrix.identity, 0.25),
            40,
            40,
            SvgFillRule.Evenodd
        )
        var worst: Int64 = 0
        var worstIndex: Int64 = -1
        for (index in 0..reference.size) {
            let expected = Int64(round(reference[index] * 255.0))
            let actual = Int64(bitmap.pixels[index * 4 + 3])
            let difference = if (actual > expected) { actual - expected } else { expected - actual }
            if (difference > worst) {
                worst = difference
                worstIndex = index
            }
        }
        if (worst > 2) {
            @Fail("evenodd 五角星 worst=${worst} at row=${worstIndex / 40} column=${worstIndex % 40}")
        }
        @Assert(worst <= 2)
    }
}
