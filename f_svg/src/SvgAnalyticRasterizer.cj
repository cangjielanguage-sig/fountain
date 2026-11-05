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
import fountain::f_base.*

/** 抗锯齿档位。 */
public enum SvgAntiAliasMode <: Equatable<SvgAntiAliasMode> & ToString {
    /** 每像素超采样，覆盖率由命中数平均（默认）。 */
    | Supersample
    /** 解析覆盖率，`samplesPerPixel` 不参与计算。 */
    | Analytic

    public operator func ==(that: SvgAntiAliasMode): Bool {
        match ((this, that)) {
            case (Supersample, Supersample) => true
            case (Analytic, Analytic) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Supersample => "Supersample"
            case Analytic => "Analytic"
        }
    }
}

// TODO(M3-9): 解析覆盖率光栅化。

private func analyticMax(left: Int64, right: Int64): Int64 {
    if (left > right) {
        left
    } else {
        right
    }
}

private func analyticMin(left: Int64, right: Int64): Int64 {
    if (left < right) {
        left
    } else {
        right
    }
}

/** 解析覆盖率的定点刻度。 */
internal let ANALYTIC_COVERAGE_SCALE: Int64 = 65535
/** 每像素行在 y 方向的子扫描线条数。 */
private let ANALYTIC_SUB_SCANLINES: Int64 = 32

private class SvgAnalyticEdge {
    let yMin: Float64
    let yMax: Float64
    let xAtMin: Float64
    let slope: Float64
    let direction: Int64

    init(yMin: Float64, yMax: Float64, xAtMin: Float64, slope: Float64, direction: Int64) {
        this.yMin = yMin
        this.yMax = yMax
        this.xAtMin = xAtMin
        this.slope = slope
        this.direction = direction
    }
}

private class SvgAnalyticHit {
    let x: Float64
    let direction: Int64

    init(x: Float64, direction: Int64) {
        this.x = x
        this.direction = direction
    }
}

private class SvgAnalyticSpan {
    let start: Float64
    let end: Float64

    init(start: Float64, end: Float64) {
        this.start = start
        this.end = end
    }
}

/**
 * 解析覆盖率：把轮廓离散为设备空间线段，逐子扫描线按像素列累加有符号覆盖长度。
 *
 * 每条线段只在它跨越的扫描线内贡献；缠绕方向由 `nonzero` / `evenodd` 独立判定，
 * 覆盖率按 y 方向子扫描线求平均并钳制到 `0..1`。
 */
internal func analyticCoverage(
    contours: Array<Array<SvgPoint>>,
    width: Int64,
    height: Int64,
    fillRule: SvgFillRule
): Array<Int64> {
    let coverage = Array<Int64>(width * height, repeat: 0)
    if (contours.size == 0) {
        return coverage
    }
    var minX = Float64.Inf
    var maxX = -Float64.Inf
    var minY = Float64.Inf
    var maxY = -Float64.Inf
    let edges = ArrayList<SvgAnalyticEdge>()
    for (contour in contours) {
        if (contour.size < 2) {
            continue
        }
        var index = 0
        while (index < contour.size) {
            let first = contour[index]
            let second = contour[(index + 1) % contour.size]
            minX = min(minX, min(first.x, second.x))
            maxX = max(maxX, max(first.x, second.x))
            minY = min(minY, min(first.y, second.y))
            maxY = max(maxY, max(first.y, second.y))
            if (first.y != second.y) {
                let yMin = if (first.y < second.y) { first.y } else { second.y }
                let yMax = if (first.y < second.y) { second.y } else { first.y }
                let xAtMin = if (first.y < second.y) { first.x } else { second.x }
                let slope = (second.x - first.x) / (second.y - first.y)
                let direction = if (second.y > first.y) { 1 } else { -1 }
                edges.add(SvgAnalyticEdge(yMin, yMax, xAtMin, slope, direction))
            }
            index++
        }
    }
    if (edges.size == 0) {
        return coverage
    }
    let firstRow = analyticMax(0, Int64(floor(minY)))
    let lastRow = analyticMin(height - 1, Int64(ceil(maxY)) - 1)
    let firstColumn = analyticMax(0, Int64(floor(minX)))
    let lastColumn = analyticMin(width - 1, Int64(ceil(maxX)) - 1)
    if (firstRow > lastRow || firstColumn > lastColumn) {
        return coverage
    }
    let accumulated = Array<Float64>(width * height, repeat: 0.0)
    let weight = 1.0 / Float64(ANALYTIC_SUB_SCANLINES)
    var row = firstRow
    while (row <= lastRow) {
        var sub = 0
        while (sub < ANALYTIC_SUB_SCANLINES) {
            let y = Float64(row) +
                (Float64(sub) + 0.5) / Float64(ANALYTIC_SUB_SCANLINES)
            let hits = collectAnalyticHits(edges, y)
            if (hits.size >= 2) {
                sortAnalyticHits(hits)
                let spans = match (fillRule) {
                    case Nonzero => analyticNonzeroSpans(hits)
                    case Evenodd => analyticEvenOddSpans(hits)
                }
                for (span in spans) {
                    accumulateAnalyticSpan(
                        accumulated,
                        width,
                        span,
                        row,
                        firstColumn,
                        lastColumn,
                        weight
                    )
                }
            }
            sub++
        }
        row++
    }
    let total = Float64(ANALYTIC_COVERAGE_SCALE)
    var index = 0
    while (index < accumulated.size) {
        let value = clampSvgUnit(accumulated[index]) * total
        coverage[index] = Int64(round(value))
        index++
    }
    coverage
}

private func collectAnalyticHits(
    edges: ArrayList<SvgAnalyticEdge>,
    y: Float64
): ArrayList<SvgAnalyticHit> {
    let hits = ArrayList<SvgAnalyticHit>()
    for (edge in edges) {
        if (y >= edge.yMin && y < edge.yMax) {
            hits.add(SvgAnalyticHit(edge.xAtMin + (y - edge.yMin) * edge.slope, edge.direction))
        }
    }
    hits
}

private func sortAnalyticHits(hits: ArrayList<SvgAnalyticHit>): Unit {
    var index = 1
    while (index < hits.size) {
        let value = hits[index]
        var position = index - 1
        while (position >= 0 && hits[position].x > value.x) {
            hits[position + 1] = hits[position]
            position--
        }
        hits[position + 1] = value
        index++
    }
}

private func analyticNonzeroSpans(hits: ArrayList<SvgAnalyticHit>): ArrayList<SvgAnalyticSpan> {
    let spans = ArrayList<SvgAnalyticSpan>()
    var winding: Int64 = 0
    var index = 0
    while (index + 1 < hits.size) {
        winding += hits[index].direction
        if (winding != 0) {
            spans.add(SvgAnalyticSpan(hits[index].x, hits[index + 1].x))
        }
        index++
    }
    spans
}

private func analyticEvenOddSpans(hits: ArrayList<SvgAnalyticHit>): ArrayList<SvgAnalyticSpan> {
    let spans = ArrayList<SvgAnalyticSpan>()
    var index = 0
    while (index + 1 < hits.size) {
        spans.add(SvgAnalyticSpan(hits[index].x, hits[index + 1].x))
        index += 2
    }
    spans
}

private func accumulateAnalyticSpan(
    accumulated: Array<Float64>,
    width: Int64,
    span: SvgAnalyticSpan,
    row: Int64,
    firstColumn: Int64,
    lastColumn: Int64,
    weight: Float64
): Unit {
    if (span.end <= span.start) {
        return
    }
    let startColumn = analyticMax(firstColumn, Int64(floor(span.start)))
    let endColumn = analyticMin(lastColumn, Int64(ceil(span.end)) - 1)
    var column = startColumn
    while (column <= endColumn) {
        let left = max(span.start, Float64(column))
        let right = min(span.end, Float64(column + 1))
        if (right > left) {
            accumulated[row * width + column] += (right - left) * weight
        }
        column++
    }
}
