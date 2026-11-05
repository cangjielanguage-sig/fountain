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

/**
 * 计算解析覆盖率：简单路径按像素精确裁剪求面积，复杂路径按固定 8×8 子采样判定内外。
 *
 * 返回每个像素的覆盖率，取值 `0..65535`。
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
    for (contour in contours) {
        for (point in contour) {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
    }
    let firstRow = analyticMax(0, Int64(floor(minY)))
    let lastRow = analyticMin(height - 1, Int64(ceil(maxY)) - 1)
    let firstColumn = analyticMax(0, Int64(floor(minX)))
    let lastColumn = analyticMin(width - 1, Int64(ceil(maxX)) - 1)
    if (firstRow > lastRow || firstColumn > lastColumn) {
        return coverage
    }
    let simple = contours.size == 1 && !selfIntersecting(contours[0])
    var row = firstRow
    while (row <= lastRow) {
        var column = firstColumn
        while (column <= lastColumn) {
            let value = if (simple) {
                let clipped = clipToPixel(contours[0], Float64(column), Float64(row))
                let area = clampSvgUnit(abs(polygonArea(clipped)))
                Int64(round(area * Float64(ANALYTIC_COVERAGE_SCALE)))
            } else {
                var inside = 0
                let samples: Int64 = 8
                var sy = 0
                while (sy < samples) {
                    var sx = 0
                    while (sx < samples) {
                        let point = SvgPoint(
                            Float64(column) + (Float64(sx) + 0.5) / Float64(samples),
                            Float64(row) + (Float64(sy) + 0.5) / Float64(samples)
                        )
                        let winding = windingNumber(contours, point)
                        let filled = match (fillRule) {
                            case Nonzero => winding != 0
                            case Evenodd => winding % 2 != 0
                        }
                        if (filled) {
                            inside++
                        }
                        sx++
                    }
                    sy++
                }
                inside * ANALYTIC_COVERAGE_SCALE / (samples * samples)
            }
            coverage[row * width + column] = value
            column++
        }
        row++
    }
    coverage
}

/** 判断单个轮廓是否自交（忽略相邻边与首末边）。 */
private func selfIntersecting(polygon: Array<SvgPoint>): Bool {
    let count = polygon.size
    if (count < 4) {
        return false
    }
    var first = 0
    while (first < count) {
        let a0 = polygon[first]
        let a1 = polygon[(first + 1) % count]
        var second = first + 1
        while (second < count) {
            if (second != first && second != (first + 1) % count &&
                first != (second + 1) % count) {
                let b0 = polygon[second]
                let b1 = polygon[(second + 1) % count]
                if (segmentsIntersect(a0, a1, b0, b1)) {
                    return true
                }
            }
            second++
        }
        first++
    }
    false
}

private func segmentsIntersect(a0: SvgPoint, a1: SvgPoint, b0: SvgPoint, b1: SvgPoint): Bool {
    let d1 = crossProduct(a0, a1, b0)
    let d2 = crossProduct(a0, a1, b1)
    let d3 = crossProduct(b0, b1, a0)
    let d4 = crossProduct(b0, b1, a1)
    if (((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) &&
        ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0))) {
        return true
    }
    false
}

private func crossProduct(a: SvgPoint, b: SvgPoint, c: SvgPoint): Float64 {
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

private func windingNumber(contours: Array<Array<SvgPoint>>, point: SvgPoint): Int64 {
    var winding: Int64 = 0
    for (contour in contours) {
        if (contour.size < 2) {
            continue
        }
        var index = 0
        while (index < contour.size) {
            let a = contour[index]
            let b = contour[(index + 1) % contour.size]
            if (a.y <= point.y) {
                if (b.y > point.y && crossProduct(a, b, point) > 0.0) {
                    winding++
                }
            } else {
                if (b.y <= point.y && crossProduct(a, b, point) < 0.0) {
                    winding--
                }
            }
            index++
        }
    }
    winding
}

private func polygonArea(polygon: Array<SvgPoint>): Float64 {
    if (polygon.size < 3) {
        return 0.0
    }
    var total = 0.0
    var index = 0
    while (index < polygon.size) {
        let current = polygon[index]
        let next = polygon[(index + 1) % polygon.size]
        total += current.x * next.y - next.x * current.y
        index++
    }
    total / 2.0
}

/** 用四条半平面把多边形裁剪到像素方块。 */
private func clipToPixel(polygon: Array<SvgPoint>, left: Float64, top: Float64): Array<SvgPoint> {
    var current = polygon
    current = clipHalfPlane(current, 0, left)
    current = clipHalfPlane(current, 1, left + 1.0)
    current = clipHalfPlane(current, 2, top)
    current = clipHalfPlane(current, 3, top + 1.0)
    current
}

/** axis: 0=left(x>=v) 1=right(x<=v) 2=top(y>=v) 3=bottom(y<=v)。 */
private func clipHalfPlane(
    polygon: Array<SvgPoint>,
    axis: Int64,
    value: Float64
): Array<SvgPoint> {
    if (polygon.size == 0) {
        return polygon
    }
    let result = ArrayList<SvgPoint>()
    var index = 0
    while (index < polygon.size) {
        let current = polygon[index]
        let next = polygon[(index + 1) % polygon.size]
        let currentInside = insideHalfPlane(current, axis, value)
        let nextInside = insideHalfPlane(next, axis, value)
        if (currentInside) {
            result.add(current)
        }
        if (currentInside != nextInside) {
            result.add(intersectHalfPlane(current, next, axis, value))
        }
        index++
    }
    result.toArray()
}

private func insideHalfPlane(point: SvgPoint, axis: Int64, value: Float64): Bool {
    match (axis) {
        case 0 => point.x >= value
        case 1 => point.x <= value
        case 2 => point.y >= value
        case 3 => point.y <= value
        case _ => false
    }
}

private func intersectHalfPlane(a: SvgPoint, b: SvgPoint, axis: Int64, value: Float64): SvgPoint {
    let useX = axis == 0 || axis == 1
    let coordinate = if (useX) {
        if (abs(b.x - a.x) < 1e-12) {
            0.0
        } else {
            (value - a.x) / (b.x - a.x)
        }
    } else {
        if (abs(b.y - a.y) < 1e-12) {
            0.0
        } else {
            (value - a.y) / (b.y - a.y)
        }
    }
    SvgPoint(a.x + (b.x - a.x) * coordinate, a.y + (b.y - a.y) * coordinate)
}
