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

private let RASTER_PI = 3.141592653589793
private let RASTER_EPSILON = 1e-12

private class SvgRasterEdge {
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

private class SvgEdgeHit {
    let x: Float64
    let direction: Int64

    init(x: Float64, direction: Int64) {
        this.x = x
        this.direction = direction
    }
}

private class SvgSpan {
    let start: Float64
    let end: Float64

    init(start: Float64, end: Float64) {
        this.start = start
        this.end = end
    }
}

/**
 * CPU 软件光栅器。
 *
 * 固定 `ss × ss` 超采样：像素行拆成 `ss` 条子扫描线，每条子扫描线在 x 方向取 `ss` 个采样点，
 * 覆盖率 = 命中数 / `ss²`。填充规则支持 nonzero 与 evenodd。
 */
public class SvgRasterizer {
    private let bitmap: SvgBitmap
    private let samplesPerPixel: Int64

    public init(bitmap: SvgBitmap, samplesPerPixel!: Int64 = 4) {
        if (samplesPerPixel != 1 && samplesPerPixel != 2 && samplesPerPixel != 4) {
            throw invalidValue("samplesPerPixel 只允许 1 / 2 / 4")
        }
        this.bitmap = bitmap
        this.samplesPerPixel = samplesPerPixel
    }

    /** 填充路径；`matrix` 把用户坐标映射到设备坐标。 */
    public func fill(
        path: SvgPathData,
        matrix!: SvgMatrix = SvgMatrix.identity,
        color!: SvgColor,
        fillRule!: SvgFillRule = SvgFillRule.Nonzero,
        opacity!: Float64 = 1.0
    ): Unit {
        if (color.alpha <= 0.0 || opacity <= 0.0) {
            return
        }
        let contours = flattenPathData(path, matrix, 0.25)
        this.fillContours(contours, color, fillRule, opacity)
    }


    /** 描边：先轮廓化，再按 nonzero 填充。宽度以用户单位计。 */
    public func stroke(
        path: SvgPathData,
        matrix!: SvgMatrix = SvgMatrix.identity,
        color!: SvgColor,
        strokeWidth!: Float64 = 1.0,
        lineCap!: SvgLineCap = SvgLineCap.Butt,
        lineJoin!: SvgLineJoin = SvgLineJoin.Miter,
        miterLimit!: Float64 = 4.0,
        dashArray!: Array<Float64> = Array<Float64>(),
        dashOffset!: Float64 = 0.0,
        opacity!: Float64 = 1.0
    ): Unit {
        if (strokeWidth <= 0.0 || color.alpha <= 0.0 || opacity <= 0.0) {
            return
        }
        let scale = matrixScale(matrix)
        let userTolerance = if (scale > RASTER_EPSILON) { 0.25 / scale } else { 0.25 }
        let userContours = flattenPathData(path, SvgMatrix.identity, userTolerance)
        let style = SvgStrokeStyle(
            strokeWidth,
            lineCap: lineCap,
            lineJoin: lineJoin,
            miterLimit: miterLimit,
            dashArray: dashArray,
            dashOffset: dashOffset
        )
        let deviceContours = SvgStrokeOutliner.outlineContours(userContours, style)
        let transformed = ArrayList<Array<SvgPoint>>()
        for (contour in deviceContours) {
            let points = ArrayList<SvgPoint>()
            for (point in contour) {
                points.add(matrix.apply(point))
            }
            transformed.add(points.toArray())
        }
        this.fillContours(transformed.toArray(), color, SvgFillRule.Nonzero, opacity)
    }

    /** 直接填充已扁平化的设备坐标轮廓，供描边等内部管线复用。 */
    internal func fillContours(
        contours: Array<Array<SvgPoint>>,
        color: SvgColor,
        fillRule: SvgFillRule,
        opacity: Float64
    ): Unit {
        if (contours.size == 0) {
            return
        }
        let edges = buildEdges(contours)
        if (edges.size == 0) {
            return
        }
        var minX = Float64.Inf
        var maxX = -Float64.Inf
        var minY = Float64.Inf
        var maxY = -Float64.Inf
        for (contour in contours) {
            for (point in contour) {
                if (point.x < minX) {
                    minX = point.x
                }
                if (point.x > maxX) {
                    maxX = point.x
                }
                if (point.y < minY) {
                    minY = point.y
                }
                if (point.y > maxY) {
                    maxY = point.y
                }
            }
        }
        let firstRow = maxInt64(0, Int64(floor(minY)))
        let lastRow = minInt64(this.bitmap.height - 1, Int64(ceil(maxY)) - 1)
        if (firstRow > lastRow) {
            return
        }
        let coverage = Array<Int64>(this.bitmap.width * this.bitmap.height, repeat: 0)
        let samples = this.samplesPerPixel
        for (row in firstRow..=lastRow) {
            for (subY in 0..samples) {
                let y = Float64(row) + (Float64(subY) + 0.5) / Float64(samples)
                let hits = collectHits(edges, y)
                if (hits.size < 2) {
                    continue
                }
                sortHits(hits)
                let spans = match (fillRule) {
                    case Nonzero => nonzeroSpans(hits)
                    case Evenodd => evenOddSpans(hits)
                }
                for (span in spans) {
                    rasterizeSpan(coverage, span, row, samples)
                }
            }
        }
        this.compositeCoverage(coverage, color, opacity)
    }

    private func rasterizeSpan(coverage: Array<Int64>, span: SvgSpan, row: Int64, samples: Int64): Unit {
        if (span.end <= span.start) {
            return
        }
        var firstColumn = Int64(floor(span.start))
        if (firstColumn < 0) {
            firstColumn = 0
        }
        var lastColumn = Int64(ceil(span.end)) - 1
        if (lastColumn >= this.bitmap.width) {
            lastColumn = this.bitmap.width - 1
        }
        if (firstColumn > lastColumn) {
            return
        }
        var column = firstColumn
        while (column <= lastColumn) {
            let base = row * this.bitmap.width + column
            for (subX in 0..samples) {
                let x = Float64(column) + (Float64(subX) + 0.5) / Float64(samples)
                if (x >= span.start && x < span.end) {
                    coverage[base]++
                }
            }
            column++
        }
    }

    private func compositeCoverage(coverage: Array<Int64>, color: SvgColor, opacity: Float64): Unit {
        let total = this.samplesPerPixel * this.samplesPerPixel
        var index = 0
        while (index < coverage.size) {
            let count = coverage[index]
            if (count > 0) {
                let coverageRatio = Float64(count) / Float64(total)
                let alpha = coverageRatio * color.alpha * opacity
                if (alpha > 0.0) {
                    let x = index % this.bitmap.width
                    let y = index / this.bitmap.width
                    this.bitmap.blend(x, y, SvgRgba.fromColor(color, alpha))
                }
            }
            index++
        }
    }
}

private func buildEdges(contours: Array<Array<SvgPoint>>): Array<SvgRasterEdge> {
    let edges = ArrayList<SvgRasterEdge>()
    for (contour in contours) {
        if (contour.size < 2) {
            continue
        }
        for (index in 0..contour.size) {
            let first = contour[index]
            let second = contour[(index + 1) % contour.size]
            if (first.y == second.y) {
                continue
            }
            let yMin = if (first.y < second.y) { first.y } else { second.y }
            let yMax = if (first.y < second.y) { second.y } else { first.y }
            let xAtMin = if (first.y < second.y) { first.x } else { second.x }
            let slope = (second.x - first.x) / (second.y - first.y)
            let direction = if (second.y > first.y) { 1 } else { -1 }
            edges.add(SvgRasterEdge(yMin, yMax, xAtMin, slope, direction))
        }
    }
    edges.toArray()
}

private func collectHits(edges: Array<SvgRasterEdge>, y: Float64): ArrayList<SvgEdgeHit> {
    let hits = ArrayList<SvgEdgeHit>()
    for (edge in edges) {
        if (y >= edge.yMin && y < edge.yMax) {
            hits.add(SvgEdgeHit(edge.xAtMin + (y - edge.yMin) * edge.slope, edge.direction))
        }
    }
    hits
}

private func sortHits(hits: ArrayList<SvgEdgeHit>): Unit {
    var i = 1
    while (i < hits.size) {
        let value = hits[i]
        var j = i - 1
        while (j >= 0 && hits[j].x > value.x) {
            hits[j + 1] = hits[j]
            j--
        }
        hits[j + 1] = value
        i++
    }
}

private func nonzeroSpans(hits: ArrayList<SvgEdgeHit>): ArrayList<SvgSpan> {
    let spans = ArrayList<SvgSpan>()
    var winding = 0
    var index = 0
    while (index + 1 < hits.size) {
        winding += hits[index].direction
        if (winding != 0) {
            spans.add(SvgSpan(hits[index].x, hits[index + 1].x))
        }
        index++
    }
    spans
}

private func evenOddSpans(hits: ArrayList<SvgEdgeHit>): ArrayList<SvgSpan> {
    let spans = ArrayList<SvgSpan>()
    var index = 0
    while (index + 1 < hits.size) {
        spans.add(SvgSpan(hits[index].x, hits[index + 1].x))
        index += 2
    }
    spans
}

private func maxInt64(first: Int64, second: Int64): Int64 {
    if (first > second) { first } else { second }
}

private func minInt64(first: Int64, second: Int64): Int64 {
    if (first < second) { first } else { second }
}

/** 把路径扁平化为设备坐标轮廓；曲线用设备像素误差 ≤ 0.25 的细分。 */
internal func flattenPathData(data: SvgPathData, matrix: SvgMatrix, tolerance: Float64): Array<Array<SvgPoint>> {
    let contours = ArrayList<Array<SvgPoint>>()
    let absolute = data.toAbsolute()
    var current = ArrayList<SvgPoint>()
    var currentX = 0.0
    var currentY = 0.0
    var startX = 0.0
    var startY = 0.0
    var lastCubicX = 0.0
    var lastCubicY = 0.0
    var hasCubic = false
    var lastQuadX = 0.0
    var lastQuadY = 0.0
    var hasQuad = false
    let scale = matrixScale(matrix)
    let userTolerance = if (scale > RASTER_EPSILON) { tolerance / scale } else { tolerance }

    for (command in absolute.commands) {
        match (command.kind) {
            case MoveTo =>
                if (current.size > 0) {
                    contours.add(current.toArray())
                }
                current = ArrayList<SvgPoint>()
                currentX = command.values[0]
                currentY = command.values[1]
                startX = currentX
                startY = currentY
                current.add(matrix.apply(SvgPoint(currentX, currentY)))
                hasCubic = false
                hasQuad = false
            case LineTo =>
                currentX = command.values[0]
                currentY = command.values[1]
                current.add(matrix.apply(SvgPoint(currentX, currentY)))
                hasCubic = false
                hasQuad = false
            case CurveTo =>
                let c1 = SvgPoint(command.values[0], command.values[1])
                let c2 = SvgPoint(command.values[2], command.values[3])
                let end = SvgPoint(command.values[4], command.values[5])
                appendCubic(current, matrix, SvgPoint(currentX, currentY), c1, c2, end, tolerance)
                currentX = end.x
                currentY = end.y
                lastCubicX = c2.x
                lastCubicY = c2.y
                hasCubic = true
                hasQuad = false
            case SmoothCurveTo =>
                let c1 = if (hasCubic) {
                    SvgPoint(2.0 * currentX - lastCubicX, 2.0 * currentY - lastCubicY)
                } else {
                    SvgPoint(currentX, currentY)
                }
                let c2 = SvgPoint(command.values[0], command.values[1])
                let end = SvgPoint(command.values[2], command.values[3])
                appendCubic(current, matrix, SvgPoint(currentX, currentY), c1, c2, end, tolerance)
                currentX = end.x
                currentY = end.y
                lastCubicX = c2.x
                lastCubicY = c2.y
                hasCubic = true
                hasQuad = false
            case QuadraticBezierTo =>
                let ctrl = SvgPoint(command.values[0], command.values[1])
                let end = SvgPoint(command.values[2], command.values[3])
                appendQuadratic(current, matrix, SvgPoint(currentX, currentY), ctrl, end, tolerance)
                currentX = end.x
                currentY = end.y
                lastQuadX = ctrl.x
                lastQuadY = ctrl.y
                hasQuad = true
                hasCubic = false
            case SmoothQuadraticBezierTo =>
                let ctrl = if (hasQuad) {
                    SvgPoint(2.0 * currentX - lastQuadX, 2.0 * currentY - lastQuadY)
                } else {
                    SvgPoint(currentX, currentY)
                }
                let end = SvgPoint(command.values[0], command.values[1])
                appendQuadratic(current, matrix, SvgPoint(currentX, currentY), ctrl, end, tolerance)
                currentX = end.x
                currentY = end.y
                lastQuadX = ctrl.x
                lastQuadY = ctrl.y
                hasQuad = true
                hasCubic = false
            case ArcTo =>
                let rx = command.values[0]
                let ry = command.values[1]
                let rotation = command.values[2]
                let large = command.values[3] != 0.0
                let sweep = command.values[4] != 0.0
                let end = SvgPoint(command.values[5], command.values[6])
                let arcPoints = arcPolyline(
                    SvgPoint(currentX, currentY),
                    rx,
                    ry,
                    rotation,
                    large,
                    sweep,
                    end,
                    userTolerance
                )
                for (index in 1..arcPoints.size) {
                    current.add(matrix.apply(arcPoints[index]))
                }
                currentX = end.x
                currentY = end.y
                hasCubic = false
                hasQuad = false
            case ClosePath =>
                if (current.size > 0) {
                    current.add(matrix.apply(SvgPoint(startX, startY)))
                }
                currentX = startX
                currentY = startY
                hasCubic = false
                hasQuad = false
            case _ => ()
        }
    }
    if (current.size > 0) {
        contours.add(current.toArray())
    }
    contours.toArray()
}

private func matrixScale(matrix: SvgMatrix): Float64 {
    let first = sqrt(matrix.a * matrix.a + matrix.b * matrix.b)
    let second = sqrt(matrix.c * matrix.c + matrix.d * matrix.d)
    if (first > second) { first } else { second }
}

private func appendCubic(
    out: ArrayList<SvgPoint>,
    matrix: SvgMatrix,
    p0: SvgPoint,
    p1: SvgPoint,
    p2: SvgPoint,
    p3: SvgPoint,
    tolerance: Float64
): Unit {
    let device = flattenCubicPolyline(
        matrix.apply(p0),
        matrix.apply(p1),
        matrix.apply(p2),
        matrix.apply(p3),
        tolerance
    )
    for (index in 1..device.size) {
        out.add(device[index])
    }
}

private func appendQuadratic(
    out: ArrayList<SvgPoint>,
    matrix: SvgMatrix,
    p0: SvgPoint,
    control: SvgPoint,
    p2: SvgPoint,
    tolerance: Float64
): Unit {
    let c1 = SvgPoint(
        p0.x + 2.0 / 3.0 * (control.x - p0.x),
        p0.y + 2.0 / 3.0 * (control.y - p0.y)
    )
    let c2 = SvgPoint(
        p2.x + 2.0 / 3.0 * (control.x - p2.x),
        p2.y + 2.0 / 3.0 * (control.y - p2.y)
    )
    appendCubic(out, matrix, p0, c1, c2, p2, tolerance)
}

/** 自适应细分三次贝塞尔；返回的折线顶点全部落在原曲线上。 */
internal func flattenCubicPolyline(
    p0: SvgPoint,
    p1: SvgPoint,
    p2: SvgPoint,
    p3: SvgPoint,
    tolerance: Float64
): Array<SvgPoint> {
    let points = ArrayList<SvgPoint>()
    points.add(p0)
    subdivideCubic(p0, p1, p2, p3, tolerance, 0, points)
    points.toArray()
}

private func subdivideCubic(
    p0: SvgPoint,
    p1: SvgPoint,
    p2: SvgPoint,
    p3: SvgPoint,
    tolerance: Float64,
    depth: Int64,
    out: ArrayList<SvgPoint>
): Unit {
    if (depth >= 16 || cubicFlatness(p0, p1, p2, p3) <= tolerance) {
        out.add(p3)
        return
    }
    let p01 = midpoint(p0, p1)
    let p12 = midpoint(p1, p2)
    let p23 = midpoint(p2, p3)
    let p012 = midpoint(p01, p12)
    let p123 = midpoint(p12, p23)
    let center = midpoint(p012, p123)
    subdivideCubic(p0, p01, p012, center, tolerance, depth + 1, out)
    subdivideCubic(center, p123, p23, p3, tolerance, depth + 1, out)
}

private func midpoint(first: SvgPoint, second: SvgPoint): SvgPoint {
    SvgPoint((first.x + second.x) / 2.0, (first.y + second.y) / 2.0)
}

private func cubicFlatness(p0: SvgPoint, p1: SvgPoint, p2: SvgPoint, p3: SvgPoint): Float64 {
    let dx = p3.x - p0.x
    let dy = p3.y - p0.y
    let chord = sqrt(dx * dx + dy * dy)
    if (chord < RASTER_EPSILON) {
        return maxFloat(distance(p1, p0), distance(p2, p0))
    }
    let first = abs((p1.x - p0.x) * dy - (p1.y - p0.y) * dx) / chord
    let second = abs((p2.x - p0.x) * dy - (p2.y - p0.y) * dx) / chord
    maxFloat(first, second)
}

private func distance(first: SvgPoint, second: SvgPoint): Float64 {
    let dx = first.x - second.x
    let dy = first.y - second.y
    sqrt(dx * dx + dy * dy)
}

private func maxFloat(first: Float64, second: Float64): Float64 {
    if (first > second) { first } else { second }
}

/** 弧转折线；步长按设备容差与半径估算。 */
private func arcPolyline(
    start: SvgPoint,
    rxIn: Float64,
    ryIn: Float64,
    rotationDegrees: Float64,
    large: Bool,
    sweep: Bool,
    end: SvgPoint,
    tolerance: Float64
): ArrayList<SvgPoint> {
    let result = ArrayList<SvgPoint>()
    result.add(start)
    var rx = abs(rxIn)
    var ry = abs(ryIn)
    if (rx < RASTER_EPSILON || ry < RASTER_EPSILON || (start.x == end.x && start.y == end.y)) {
        result.add(end)
        return result
    }
    let phi = rotationDegrees * RASTER_PI / 180.0
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (start.x - end.x) / 2.0
    let dy = (start.y - end.y) / 2.0
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
    if (lambda > 1.0) {
        let scale = sqrt(lambda)
        rx = rx * scale
        ry = ry * scale
    }
    let sign = if (large == sweep) { -1.0 } else { 1.0 }
    let rx2 = rx * rx
    let ry2 = ry * ry
    let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
    let coefficient = if (denominator < RASTER_EPSILON) {
        0.0
    } else {
        sign * sqrt(if (numerator < 0.0) { 0.0 } else { numerator / denominator })
    }
    let cxp = coefficient * rx * y1p / ry
    let cyp = coefficient * -ry * x1p / rx
    let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2.0
    let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2.0
    let ux = (x1p - cxp) / rx
    let uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx
    let vy = (-y1p - cyp) / ry
    let theta1 = atan2(uy, ux)
    var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    if (!sweep && delta > 0.0) {
        delta -= 2.0 * RASTER_PI
    } else if (sweep && delta < 0.0) {
        delta += 2.0 * RASTER_PI
    }
    let radius = maxFloat(rx, ry)
    let safeTolerance = if (tolerance > 0.0) { tolerance } else { 0.25 }
    var step = 2.0 * acos(clampSvgUnit(1.0 - safeTolerance / radius))
    if (!(step > 0.01)) {
        step = RASTER_PI / 16.0
    }
    var segments = Int64(ceil(abs(delta) / step))
    if (segments < 1) {
        segments = 1
    }
    if (segments > 256) {
        segments = 256
    }
    for (index in 1..=segments) {
        if (index == segments) {
            result.add(end)
        } else {
            let angle = theta1 + delta * Float64(index) / Float64(segments)
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            let x = cx + rx * cosPhi * cosAngle - ry * sinPhi * sinAngle
            let y = cy + rx * sinPhi * cosAngle + ry * cosPhi * sinAngle
            result.add(SvgPoint(x, y))
        }
    }
    result
}
