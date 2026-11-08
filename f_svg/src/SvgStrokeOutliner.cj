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

/** 描边参数。宽度与 dash 长度使用用户单位。 */
public struct SvgStrokeStyle {
    public let width: Float64
    public let lineCap: SvgLineCap
    public let lineJoin: SvgLineJoin
    public let miterLimit: Float64
    public let dashArray: Array<Float64>
    public let dashOffset: Float64

    public init(
        width: Float64,
        lineCap!: SvgLineCap = SvgLineCap.Butt,
        lineJoin!: SvgLineJoin = SvgLineJoin.Miter,
        miterLimit!: Float64 = 4.0,
        dashArray!: Array<Float64> = Array<Float64>(),
        dashOffset!: Float64 = 0.0
    ) {
        this.width = width
        this.lineCap = lineCap
        this.lineJoin = lineJoin
        this.miterLimit = miterLimit
        this.dashArray = dashArray
        this.dashOffset = dashOffset
    }
}

private let STROKE_EPSILON = 1e-9

/**
 * 描边轮廓化：把中心线拆成线段四边形、连接处多边形与端点形状，
 * 输出一组同向闭合轮廓，交给 nonzero 填充自然合并。
 *
 * 这种「并集」表示与左右偏移轮廓等价，但更容易处理自交与 dash。
 */
public class SvgStrokeOutliner {
    /** 逐条轮廓描边；每条轮廓隐式闭合。 */
    public static func outlineContours(
        contours: Array<Array<SvgPoint>>,
        style: SvgStrokeStyle
    ): Array<Array<SvgPoint>> {
        let result = ArrayList<Array<SvgPoint>>()
        for (contour in contours) {
            var points = contour
            var closed = false
            if (points.size > 1 && points[0] == points[points.size - 1]) {
                closed = true
                points = points[0..points.size - 1]
            }
            if (style.dashArray.size == 0 || !isValidDash(style.dashArray)) {
                appendAll(result, outlineOne(points, closed, style))
            } else {
                for (piece in dashPieces(points, closed, style)) {
                    appendAll(result, outlineOne(piece, false, style))
                }
            }
        }
        result.toArray()
    }

    /** 描一条折线；`closed` 为 true 时首尾相连且不加端点帽。 */
    public static func outlinePolyline(
        points: Array<SvgPoint>,
        closed: Bool,
        style: SvgStrokeStyle
    ): Array<Array<SvgPoint>> {
        if (style.width <= 0.0) {
            return Array<Array<SvgPoint>>()
        }
        if (style.dashArray.size == 0 || !isValidDash(style.dashArray)) {
            return outlineOne(points, closed, style)
        }
        let pieces = dashPieces(points, closed, style)
        let result = ArrayList<Array<SvgPoint>>()
        for (piece in pieces) {
            appendAll(result, outlineOne(piece, false, style))
        }
        result.toArray()
    }

    /**
     * 元素级描边轮廓：rect / circle / ellipse / line 走解析路径，
     * 其余元素按点列或路径扁平化后走通用 outliner。
     */
    public static func outlineElement(element: SvgElement, style: SvgStrokeStyle): ?Array<Array<SvgPoint>> {
        if (style.width <= 0.0) {
            return Some(Array<Array<SvgPoint>>())
        }
        match (element) {
            case rect: SvgRect => return rectOutline(rect, style)
            case circle: SvgCircle => return circleOutline(circle, style)
            case ellipse: SvgEllipse => return ellipseOutline(ellipse, style)
            case line: SvgLine =>
                return Some(
                    outlinePolyline(
                        [SvgPoint(lengthOrZero(line.x1), lengthOrZero(line.y1)),
                        SvgPoint(lengthOrZero(line.x2), lengthOrZero(line.y2))],
                        false,
                        style
                    )
                )
            case polyline: SvgPolyline =>
                match (polyline.points) {
                    case Some(list) => return Some(outlinePolyline(list.points, false, style))
                    case None => return None
                }
            case polygon: SvgPolygon =>
                match (polygon.points) {
                    case Some(list) => return Some(outlinePolyline(list.points, true, style))
                    case None => return None
                }
            case path: SvgPath =>
                match (path.d) {
                    case Some(data) =>
                        return Some(outlineContours(flattenPathData(data, SvgMatrix.identity, 0.25), style))
                    case None => return None
                }
            case _ => ()
        }
        None
    }
}

private func appendAll(target: ArrayList<Array<SvgPoint>>, source: Array<Array<SvgPoint>>): Unit {
    for (item in source) {
        target.add(item)
    }
}

private func isValidDash(dashArray: Array<Float64>): Bool {
    if (dashArray.size == 0) {
        return true
    }
    for (value in dashArray) {
        if (!isFiniteSvgNumber(value) || value < 0.0) {
            return false
        }
    }
    true
}

private func outlineOne(points: Array<SvgPoint>, closed: Bool, style: SvgStrokeStyle): Array<Array<SvgPoint>> {
    let result = ArrayList<Array<SvgPoint>>()
    let half = style.width / 2.0
    let cleaned = removeDuplicatePoints(points)
    if (cleaned.size == 0) {
        return result.toArray()
    }
    if (cleaned.size == 1) {
        if (style.lineCap == SvgLineCap.Round) {
            addContour(result, circlePolygonForStroke(cleaned[0].x, cleaned[0].y, half, 0.25))
        } else if (style.lineCap == SvgLineCap.Square) {
            addContour(
                result,
                [
                    SvgPoint(cleaned[0].x - half, cleaned[0].y - half),
                    SvgPoint(cleaned[0].x + half, cleaned[0].y - half),
                    SvgPoint(cleaned[0].x + half, cleaned[0].y + half),
                    SvgPoint(cleaned[0].x - half, cleaned[0].y + half)
                ]
            )
        }
        return result.toArray()
    }

    let segmentCount = if (closed) { cleaned.size } else { cleaned.size - 1 }
    for (index in 0..segmentCount) {
        let first = cleaned[index]
        let second = cleaned[(index + 1) % cleaned.size]
        let dx = second.x - first.x
        let dy = second.y - first.y
        let length = sqrt(dx * dx + dy * dy)
        if (length < STROKE_EPSILON) {
            continue
        }
        let nx = -dy / length * half
        let ny = dx / length * half
        addContour(
            result,
            [
                SvgPoint(first.x + nx, first.y + ny),
                SvgPoint(second.x + nx, second.y + ny),
                SvgPoint(second.x - nx, second.y - ny),
                SvgPoint(first.x - nx, first.y - ny)
            ]
        )
    }

    if (closed) {
        for (index in 0..cleaned.size) {
            addJoin(
                result,
                cleaned[(index - 1 + cleaned.size) % cleaned.size],
                cleaned[index],
                cleaned[(index + 1) % cleaned.size],
                half,
                style
            )
        }
    } else {
        for (index in 1..cleaned.size - 1) {
            addJoin(result, cleaned[index - 1], cleaned[index], cleaned[index + 1], half, style)
        }
        let first = cleaned[0]
        let second = cleaned[1]
        addCap(result, first, second, half, style.lineCap)
        let last = cleaned[cleaned.size - 1]
        let previous = cleaned[cleaned.size - 2]
        addCap(result, last, previous, half, style.lineCap)
    }
    result.toArray()
}

private func removeDuplicatePoints(points: Array<SvgPoint>): Array<SvgPoint> {
    let result = ArrayList<SvgPoint>()
    for (point in points) {
        if (result.size == 0 || distanceSquared(result[result.size - 1], point) > STROKE_EPSILON) {
            result.add(point)
        }
    }
    result.toArray()
}

private func distanceSquared(first: SvgPoint, second: SvgPoint): Float64 {
    let dx = first.x - second.x
    let dy = first.y - second.y
    dx * dx + dy * dy
}

private func addCap(
    result: ArrayList<Array<SvgPoint>>,
    endpoint: SvgPoint,
    adjacent: SvgPoint,
    half: Float64,
    cap: SvgLineCap
): Unit {
    if (cap == SvgLineCap.Butt) {
        return
    }
    let dx = endpoint.x - adjacent.x
    let dy = endpoint.y - adjacent.y
    let length = sqrt(dx * dx + dy * dy)
    if (length < STROKE_EPSILON) {
        return
    }
    let ux = dx / length
    let uy = dy / length
    let nx = -uy * half
    let ny = ux * half
    if (cap == SvgLineCap.Round) {
        addContour(result, circlePolygonForStroke(endpoint.x, endpoint.y, half, 0.25))
    } else {
        let outwardX = ux
        let outwardY = uy
        addContour(
            result,
            [
                SvgPoint(endpoint.x + nx, endpoint.y + ny),
                SvgPoint(endpoint.x + outwardX * half + nx, endpoint.y + outwardY * half + ny),
                SvgPoint(endpoint.x + outwardX * half - nx, endpoint.y + outwardY * half - ny),
                SvgPoint(endpoint.x - nx, endpoint.y - ny)
            ]
        )
    }
}

private func addJoin(
    result: ArrayList<Array<SvgPoint>>,
    previous: SvgPoint,
    vertex: SvgPoint,
    next: SvgPoint,
    half: Float64,
    style: SvgStrokeStyle
): Unit {
    let v1x = vertex.x - previous.x
    let v1y = vertex.y - previous.y
    let v2x = next.x - vertex.x
    let v2y = next.y - vertex.y
    let length1 = sqrt(v1x * v1x + v1y * v1y)
    let length2 = sqrt(v2x * v2x + v2y * v2y)
    if (length1 < STROKE_EPSILON || length2 < STROKE_EPSILON) {
        return
    }
    let u1x = v1x / length1
    let u1y = v1y / length1
    let u2x = v2x / length2
    let u2y = v2y / length2
    let dot = u1x * u2x + u1y * u2y
    let denominator = 1.0 + dot
    if (denominator < 1e-9) {
        return
    }
    let cross = u1x * u2y - u1y * u2x
    let sign = if (cross > 0.0) { -1.0 } else { 1.0 }
    let n1x = -u1y
    let n1y = u1x
    let n2x = -u2y
    let n2y = u2x
    if (style.lineJoin == SvgLineJoin.Round || style.lineJoin == SvgLineJoin.Arcs) {
        addContour(result, circlePolygonForStroke(vertex.x, vertex.y, half, 0.25))
        return
    }
    let outer1 = SvgPoint(vertex.x + sign * n1x * half, vertex.y + sign * n1y * half)
    let outer2 = SvgPoint(vertex.x + sign * n2x * half, vertex.y + sign * n2y * half)
    if (style.lineJoin == SvgLineJoin.Miter || style.lineJoin == SvgLineJoin.MiterClip) {
        let ratio = sqrt(2.0 / denominator)
        var dirX = sign * (n1x + n2x)
        var dirY = sign * (n1y + n2y)
        let dirLength = sqrt(dirX * dirX + dirY * dirY)
        if (dirLength > STROKE_EPSILON) {
            dirX = dirX / dirLength
            dirY = dirY / dirLength
            if (ratio <= style.miterLimit) {
                let tip = SvgPoint(vertex.x + dirX * half * ratio, vertex.y + dirY * half * ratio)
                addContour(result, [vertex, outer1, tip, outer2])
                return
            }
            if (style.lineJoin == SvgLineJoin.MiterClip && style.miterLimit > 0.0) {
                // 在距顶点 `miterlimit × half` 处作垂直于角平分线的截断线，
                // 求两条外边与截断线的交点，保留截断后的尖角区域。
                let limitDistance = style.miterLimit * half
                let firstBase = (outer1.x - vertex.x) * dirX + (outer1.y - vertex.y) * dirY
                let firstSlope = u1x * dirX + u1y * dirY
                let secondBase = (outer2.x - vertex.x) * dirX + (outer2.y - vertex.y) * dirY
                let secondSlope = u2x * dirX + u2y * dirY
                if (abs(firstSlope) > STROKE_EPSILON && abs(secondSlope) > STROKE_EPSILON) {
                    let firstT = (limitDistance - firstBase) / firstSlope
                    let secondT = (limitDistance - secondBase) / secondSlope
                    let firstClip = SvgPoint(outer1.x + u1x * firstT, outer1.y + u1y * firstT)
                    let secondClip = SvgPoint(outer2.x + u2x * secondT, outer2.y + u2y * secondT)
                    addContour(result, [vertex, outer1, firstClip, secondClip, outer2])
                    return
                }
            }
        }
    }
    addContour(result, [vertex, outer1, outer2])
}

private func addContour(result: ArrayList<Array<SvgPoint>>, points: Array<SvgPoint>): Unit {
    if (points.size < 3) {
        return
    }
    result.add(ensurePositiveOrientation(points))
}

private func ensurePositiveOrientation(points: Array<SvgPoint>): Array<SvgPoint> {
    if (signedArea(points) >= 0.0) {
        return points
    }
    let reversed = ArrayList<SvgPoint>()
    var index = points.size - 1
    while (index >= 0) {
        reversed.add(points[index])
        index--
    }
    reversed.toArray()
}

private func signedArea(points: Array<SvgPoint>): Float64 {
    var area = 0.0
    for (index in 0..points.size) {
        let first = points[index]
        let second = points[(index + 1) % points.size]
        area += first.x * second.y - second.x * first.y
    }
    area / 2.0
}

/** 圆/圆弧多边形近似；误差 ≤ 半像素量级。测试与解析轮廓共用。 */
internal func circlePolygonForStroke(cx: Float64, cy: Float64, radius: Float64, tolerance: Float64): Array<SvgPoint> {
    if (radius <= 0.0) {
        return Array<SvgPoint>()
    }
    let safeTolerance = if (tolerance > 0.0) { tolerance } else { 0.25 }
    let ratio = 1.0 - safeTolerance / radius
    var step = 2.0 * acos(clampUnitForStroke(ratio))
    if (!(step > 0.01)) {
        step = 3.141592653589793 / 16.0
    }
    var segments = Int64(ceil(2.0 * 3.141592653589793 / step))
    if (segments < 8) {
        segments = 8
    }
    if (segments > 256) {
        segments = 256
    }
    let points = ArrayList<SvgPoint>()
    for (index in 0..segments) {
        let angle = 2.0 * 3.141592653589793 * Float64(index) / Float64(segments)
        points.add(SvgPoint(cx + radius * cos(angle), cy + radius * sin(angle)))
    }
    points.toArray()
}

private func clampUnitForStroke(value: Float64): Float64 {
    if (value < -1.0) {
        -1.0
    } else if (value > 1.0) {
        1.0
    } else {
        value
    }
}

private func ellipsePolygonForStroke(
    cx: Float64,
    cy: Float64,
    rx: Float64,
    ry: Float64,
    tolerance: Float64
): Array<SvgPoint> {
    if (rx <= 0.0 || ry <= 0.0) {
        return Array<SvgPoint>()
    }
    let radius = if (rx > ry) { rx } else { ry }
    let circle = circlePolygonForStroke(0.0, 0.0, radius, tolerance)
    let points = ArrayList<SvgPoint>()
    for (point in circle) {
        points.add(SvgPoint(cx + point.x / radius * rx, cy + point.y / radius * ry))
    }
    points.toArray()
}

private func rectOutline(rect: SvgRect, style: SvgStrokeStyle): ?Array<Array<SvgPoint>> {
    let width = match (rect.width) {
        case Some(value) => value.value
        case None => return None
    }
    let height = match (rect.height) {
        case Some(value) => value.value
        case None => return None
    }
    if (width <= 0.0 || height <= 0.0) {
        return None
    }
    let x = lengthOrZero(rect.x)
    let y = lengthOrZero(rect.y)
    if ((style.lineJoin != SvgLineJoin.Miter && style.lineJoin != SvgLineJoin.MiterClip) || style.miterLimit < 1.4142135623730951) {
        return Some(
            SvgStrokeOutliner.outlinePolyline(
                [SvgPoint(x, y), SvgPoint(x + width, y), SvgPoint(x + width, y + height), SvgPoint(x, y + height)],
                true,
                style
            )
        )
    }
    let half = style.width / 2.0
    let result = ArrayList<Array<SvgPoint>>()
    addContour(
        result,
        [
            SvgPoint(x - half, y - half),
            SvgPoint(x + width + half, y - half),
            SvgPoint(x + width + half, y + height + half),
            SvgPoint(x - half, y + height + half)
        ]
    )
    let innerWidth = width - style.width
    let innerHeight = height - style.width
    if (innerWidth > 0.0 && innerHeight > 0.0) {
        let inner = [
            SvgPoint(x + half, y + half),
            SvgPoint(x + half + innerWidth, y + half),
            SvgPoint(x + half + innerWidth, y + half + innerHeight),
            SvgPoint(x + half, y + half + innerHeight)
        ]
        result.add(reverseContour(ensurePositiveOrientation(inner)))
    }
    result.toArray()
}

private func reverseContour(points: Array<SvgPoint>): Array<SvgPoint> {
    let reversed = ArrayList<SvgPoint>()
    var index = points.size - 1
    while (index >= 0) {
        reversed.add(points[index])
        index--
    }
    reversed.toArray()
}

private func circleOutline(circle: SvgCircle, style: SvgStrokeStyle): ?Array<Array<SvgPoint>> {
    let radius = match (circle.r) {
        case Some(value) => value.value
        case None => return None
    }
    if (radius <= 0.0) {
        return None
    }
    let cx = lengthOrZero(circle.cx)
    let cy = lengthOrZero(circle.cy)
    let half = style.width / 2.0
    let result = ArrayList<Array<SvgPoint>>()
    addContour(result, circlePolygonForStroke(cx, cy, radius + half, 0.25))
    if (radius - half > 0.0) {
        result.add(reverseContour(ensurePositiveOrientation(circlePolygonForStroke(cx, cy, radius - half, 0.25))))
    }
    result.toArray()
}

private func ellipseOutline(ellipse: SvgEllipse, style: SvgStrokeStyle): ?Array<Array<SvgPoint>> {
    let rx = match (ellipse.rx) {
        case Some(value) => value.value
        case None => return None
    }
    let ry = match (ellipse.ry) {
        case Some(value) => value.value
        case None => return None
    }
    if (rx <= 0.0 || ry <= 0.0) {
        return None
    }
    let cx = lengthOrZero(ellipse.cx)
    let cy = lengthOrZero(ellipse.cy)
    let half = style.width / 2.0
    let result = ArrayList<Array<SvgPoint>>()
    addContour(result, ellipsePolygonForStroke(cx, cy, rx + half, ry + half, 0.25))
    if (rx - half > 0.0 && ry - half > 0.0) {
        result.add(
            reverseContour(ensurePositiveOrientation(ellipsePolygonForStroke(cx, cy, rx - half, ry - half, 0.25)))
        )
    }
    result.toArray()
}

/** dash 切分；返回每条 dash 的开放折线。 */
private func dashPieces(points: Array<SvgPoint>, closed: Bool, style: SvgStrokeStyle): Array<Array<SvgPoint>> {
    let cleaned = removeDuplicatePoints(points)
    if (style.dashArray.size == 0 || !isValidDash(style.dashArray)) {
        return [cleaned]
    }
    var pattern = style.dashArray
    var sum = 0.0
    for (value in pattern) {
        sum += value
    }
    if (sum <= STROKE_EPSILON) {
        return Array<Array<SvgPoint>>()
    }
    if (pattern.size % 2 == 1) {
        let duplicated = ArrayList<Float64>()
        for (value in pattern) {
            duplicated.add(value)
        }
        for (value in pattern) {
            duplicated.add(value)
        }
        pattern = duplicated.toArray()
    }
    var offset = fmod(style.dashOffset, sum)
    if (offset < 0.0) {
        offset += sum
    }
    var index = 0
    var remaining = pattern[0]
    while (offset >= remaining && remaining > STROKE_EPSILON) {
        offset -= remaining
        index = (index + 1) % pattern.size
        remaining = pattern[index]
    }
    remaining -= offset
    if (remaining <= STROKE_EPSILON) {
        index = (index + 1) % pattern.size
        remaining = pattern[index]
    }
    var on = index % 2 == 0
    let result = ArrayList<Array<SvgPoint>>()
    var current = ArrayList<SvgPoint>()
    let segmentCount = if (closed) { cleaned.size } else { cleaned.size - 1 }
    for (segmentIndex in 0..segmentCount) {
        let start = cleaned[segmentIndex]
        let end = cleaned[(segmentIndex + 1) % cleaned.size]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        if (length < STROKE_EPSILON) {
            continue
        }
        var consumed = 0.0
        while (consumed < length - STROKE_EPSILON) {
            let take = if (length - consumed < remaining) { length - consumed } else { remaining }
            let segmentEnd = SvgPoint(start.x + dx * (consumed + take) / length, start.y + dy * (consumed + take) / length)
            if (on) {
                if (current.size == 0) {
                    current.add(SvgPoint(start.x + dx * consumed / length, start.y + dy * consumed / length))
                }
                current.add(segmentEnd)
            }
            consumed += take
            remaining -= take
            if (remaining <= STROKE_EPSILON) {
                if (on && current.size > 0) {
                    result.add(current.toArray())
                    current = ArrayList<SvgPoint>()
                }
                index = (index + 1) % pattern.size
                remaining = pattern[index]
                on = index % 2 == 0
                if (on && consumed < length - STROKE_EPSILON) {
                    current.add(SvgPoint(start.x + dx * consumed / length, start.y + dy * consumed / length))
                }
            }
        }
    }
    if (on && current.size > 1) {
        result.add(current.toArray())
    }
    result.toArray()
}
