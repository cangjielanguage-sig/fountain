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
    /** 45° 斜线两侧相邻像素覆盖率之和约为 1。 */
    @TestCase
    public func diagonalCoverageConservation(): Unit {
        let contours = flattenPathData(ANALYTIC_TRIANGLE, SvgMatrix.identity, 0.25)
        let coverage = analyticCoverage(contours, 4, 4, SvgFillRule.Nonzero)
        let left = Float64(coverage[0 * 4 + 0]) / 65535.0
        let right = Float64(coverage[1 * 4 + 1]) / 65535.0
        @Assert(abs(left + right - 1.0) <= 1.0 / 255.0)
        @Assert(left > 0.0 && left < 1.0)
        @Assert(right > 0.0 && right < 1.0)
    }

    /** 圆形解析覆盖率与 4× 超采样平均差 ≤ 2/255。 */
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
        let supersample = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 4, antiAlias: SvgAntiAliasMode.Supersample)
        ).render(document)
        var total: Float64 = 0.0
        for (index in 0..analytic.pixels.size) {
            total += abs(Float64(analytic.pixels[index]) - Float64(supersample.pixels[index]))
        }
        let average = total / Float64(analytic.pixels.size)
        @Assert(average <= 2.0)
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
            "<circle cx=\"20\" cy=\"20\" r=\"15\" fill=\"url(#p)\" marker-end=\"url(#m)\"/>" +
            "</g></svg>"
        )
        let options = SvgRenderOptions(samplesPerPixel: 4, antiAlias: SvgAntiAliasMode.Analytic)
        let first = SvgRenderer(options: options).render(document)
        let second = SvgRenderer(options: options).render(document)
        @Assert(first.pixels == second.pixels)
    }
}
