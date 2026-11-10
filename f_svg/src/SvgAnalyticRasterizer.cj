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

private func analyticMaxReal(left: Float64, right: Float64): Float64 {
    if (left > right) {
        left
    } else {
        right
    }
}

private func analyticMinReal(left: Float64, right: Float64): Float64 {
    if (left < right) {
        left
    } else {
        right
    }
}

/** 解析覆盖率的定点刻度。 */
internal let ANALYTIC_COVERAGE_SCALE: Int64 = 65535
/** 事件去重与零宽度判定阈值。 */
private let ANALYTIC_EPSILON: Float64 = 1e-9

/**
 * 一条有向边，按 `x = xAtMin + (y - yMin) * slope` 参数化，[yMin, yMax] 为 y 覆盖区间。
 */
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

    func xAt(y: Float64): Float64 {
        this.xAtMin + (y - this.yMin) * this.slope
    }
}

private class SvgAnalyticHit {
    let x: Float64
    let direction: Int64
    let edge: SvgAnalyticEdge

    init(x: Float64, direction: Int64, edge: SvgAnalyticEdge) {
        this.x = x
        this.direction = direction
        this.edge = edge
    }
}

/**
 * 解析覆盖率：把轮廓离散为设备空间线段，按像素行内的事件区间精确积分。
 *
 * 行内先按顶点 y 与线段交点 y 分割，保证每个子区间内边的左右次序不变；
 * 再对每个内部区间逐像素列累加 `∫ (clip(xRight) - clip(xLeft)) dy`，
 * 即按像素列累加有符号面积。`nonzero` 用绕数判定内部，`evenodd` 用奇偶配对。
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
    if (firstRow > lastRow) {
        return coverage
    }
    let accumulated = Array<Float64>(width * height, repeat: 0.0)
    var row = firstRow
    while (row <= lastRow) {
        accumulateAnalyticRow(edges, accumulated, width, row, fillRule)
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

/** 处理一行：收集顶点与交点事件，逐子区间积分到像素列。 */
private func accumulateAnalyticRow(
    edges: ArrayList<SvgAnalyticEdge>,
    accumulated: Array<Float64>,
    width: Int64,
    row: Int64,
    fillRule: SvgFillRule
): Unit {
    let rowTop = Float64(row)
    let rowBottom = rowTop + 1.0
    let active = ArrayList<SvgAnalyticEdge>()
    for (edge in edges) {
        if (edge.yMax > rowTop && edge.yMin < rowBottom) {
            active.add(edge)
        }
    }
    if (active.size == 0) {
        return
    }
    let events = ArrayList<Float64>()
    events.add(rowTop)
    events.add(rowBottom)
    for (edge in active) {
        if (edge.yMin > rowTop + ANALYTIC_EPSILON && edge.yMin < rowBottom - ANALYTIC_EPSILON) {
            events.add(edge.yMin)
        }
        if (edge.yMax > rowTop + ANALYTIC_EPSILON && edge.yMax < rowBottom - ANALYTIC_EPSILON) {
            events.add(edge.yMax)
        }
    }
    var first = 0
    while (first + 1 < active.size) {
        var second = first + 1
        while (second < active.size) {
            match (analyticCrossingY(active[first], active[second])) {
                case Some(value) =>
                    if (value > rowTop + ANALYTIC_EPSILON &&
                        value < rowBottom - ANALYTIC_EPSILON) {
                        events.add(value)
                    }
                case None => ()
            }
            second++
        }
        first++
    }
    sortAnalyticValues(events)
    var index = 0
    while (index + 1 < events.size) {
        let ya = events[index]
        let yb = events[index + 1]
        if (yb - ya > ANALYTIC_EPSILON) {
            accumulateAnalyticBand(active, accumulated, width, row, ya, yb, fillRule)
        }
        index++
    }
}

/** 在一个左右次序不变的子区间内按填充规则求内部区间并积分。 */
private func accumulateAnalyticBand(
    active: ArrayList<SvgAnalyticEdge>,
    accumulated: Array<Float64>,
    width: Int64,
    row: Int64,
    ya: Float64,
    yb: Float64,
    fillRule: SvgFillRule
): Unit {
    let middle = (ya + yb) * 0.5
    let hits = ArrayList<SvgAnalyticHit>()
    for (edge in active) {
        if (middle >= edge.yMin && middle < edge.yMax) {
            hits.add(SvgAnalyticHit(edge.xAt(middle), edge.direction, edge))
        }
    }
    if (hits.size < 2) {
        return
    }
    sortAnalyticHits(hits)
    var index = 0
    var winding: Int64 = 0
    while (index + 1 < hits.size) {
        let spanStart = hits[index]
        let spanEnd = hits[index + 1]
        var inside = true
        match (fillRule) {
            case Nonzero =>
                winding += spanStart.direction
                inside = winding != 0
            case Evenodd => inside = index % 2 == 0
        }
        if (inside) {
            accumulateAnalyticEdges(
                accumulated,
                width,
                row,
                spanStart.edge,
                spanEnd.edge,
                ya,
                yb
            )
        }
        if (fillRule == SvgFillRule.Evenodd) {
            index += 2
        } else {
            index++
        }
    }
}

/** 对 [ya, yb] 区间，把左右边界之间的面积精确累加到像素列。 */
private func accumulateAnalyticEdges(
    accumulated: Array<Float64>,
    width: Int64,
    row: Int64,
    leftEdge: SvgAnalyticEdge,
    rightEdge: SvgAnalyticEdge,
    ya: Float64,
    yb: Float64
): Unit {
    let leftA = leftEdge.xAt(ya)
    let leftB = leftEdge.xAt(yb)
    let rightA = rightEdge.xAt(ya)
    let rightB = rightEdge.xAt(yb)
    let minimum = analyticMinReal(analyticMinReal(leftA, leftB), analyticMinReal(rightA, rightB))
    let maximum = analyticMaxReal(analyticMaxReal(leftA, leftB), analyticMaxReal(rightA, rightB))
    var column = analyticMax(0, Int64(floor(minimum)))
    let lastColumn = analyticMin(width - 1, Int64(ceil(maximum)) - 1)
    while (column <= lastColumn) {
        let right = analyticEdgeColumnIntegral(rightEdge, column, ya, yb)
        let left = analyticEdgeColumnIntegral(leftEdge, column, ya, yb)
        let contribution = right - left
        if (contribution > 0.0) {
            accumulated[row * width + column] += contribution
        }
        column++
    }
}

/**
 * `∫_ya^yb clamp(x(y) - column, 0, 1) dy` 的精确值。
 *
 * 线性 x(y) 与 `clamp` 的分段点（column、column+1）把区间切成至多三段，
 * 每段内被积函数为 0、1 或线性，直接累加梯形面积。
 */
private func analyticEdgeColumnIntegral(
    edge: SvgAnalyticEdge,
    column: Int64,
    ya: Float64,
    yb: Float64
): Float64 {
    let xa = edge.xAt(ya)
    let xb = edge.xAt(yb)
    let left = Float64(column)
    let delta = xb - xa
    let values = ArrayList<Float64>()
    values.add(0.0)
    values.add(1.0)
    if (abs(delta) > ANALYTIC_EPSILON) {
        let lower = (left - xa) / delta
        if (lower > 0.0 && lower < 1.0) {
            values.add(lower)
        }
        let upper = (left + 1.0 - xa) / delta
        if (upper > 0.0 && upper < 1.0) {
            values.add(upper)
        }
    }
    sortAnalyticValues(values)
    var total = 0.0
    var index = 0
    while (index + 1 < values.size) {
        let u0 = values[index]
        let u1 = values[index + 1]
        if (u1 - u0 > ANALYTIC_EPSILON) {
            let x0 = xa + delta * u0
            let x1 = xa + delta * u1
            let dy = (u1 - u0) * (yb - ya)
            let low = analyticMinReal(x0, x1)
            let high = analyticMaxReal(x0, x1)
            if (low >= left + 1.0) {
                total += dy
            } else if (high > left) {
                total += (clampSvgUnit(x0 - left) + clampSvgUnit(x1 - left)) * 0.5 * dy
            }
        }
        index++
    }
    total
}

/** 两条非水平边的交点 y；平行或不相交返回 `None`。 */
private func analyticCrossingY(first: SvgAnalyticEdge, second: SvgAnalyticEdge): ?Float64 {
    let denominator = first.slope - second.slope
    if (abs(denominator) < ANALYTIC_EPSILON) {
        return None
    }
    let offset = second.xAtMin - first.xAtMin + first.yMin * first.slope -
        second.yMin * second.slope
    let y = offset / denominator
    if (y <= first.yMin || y >= first.yMax || y <= second.yMin || y >= second.yMax) {
        return None
    }
    Some(y)
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

private func sortAnalyticValues(values: ArrayList<Float64>): Unit {
    var index = 1
    while (index < values.size) {
        let value = values[index]
        var position = index - 1
        while (position >= 0 && values[position] > value) {
            values[position + 1] = values[position]
            position--
        }
        values[position + 1] = value
        index++
    }
}
