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

/** 几何包围盒计算。路径、描边与变换后包围盒在 M2.2 后续任务补齐。 */
public class SvgGeometry {
    /** 元素自身坐标系中的几何包围盒（不含描边）。 */
    public static func bounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds {
        match (element) {
            case rect: SvgRect => return rectBounds(rect)
            case circle: SvgCircle => return circleBounds(circle)
            case ellipse: SvgEllipse => return ellipseBounds(ellipse)
            case line: SvgLine => return lineBounds(line)
            case polyline: SvgPolyline => return pointsBounds(polyline.points)
            case polygon: SvgPolygon => return pointsBounds(polygon.points)
            case _ => ()
        }
        None
    }

    /** 含描边的包围盒。 */
    public static func strokeBounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds {
        match (bounds(element, style: style)) {
            case Some(box) => Some(box)
            case None => None
        }
    }

    /** 应用元素及其祖先 `transform` 后的包围盒。 */
    public static func absoluteBounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds {
        match (bounds(element, style: style)) {
            case Some(box) => Some(box)
            case None => None
        }
    }
}

private func rectBounds(rect: SvgRect): ?SvgBounds {
    let width = match (rect.width) {
        case Some(value) => value.value
        case None => return None
    }
    let height = match (rect.height) {
        case Some(value) => value.value
        case None => return None
    }
    if (width < 0.0 || height < 0.0) {
        return None
    }
    let x = lengthOrZero(rect.x)
    let y = lengthOrZero(rect.y)
    Some(SvgBounds(x, y, width, height))
}

private func circleBounds(circle: SvgCircle): ?SvgBounds {
    let radius = match (circle.r) {
        case Some(value) => value.value
        case None => return None
    }
    if (radius < 0.0) {
        return None
    }
    let cx = lengthOrZero(circle.cx)
    let cy = lengthOrZero(circle.cy)
    Some(SvgBounds(cx - radius, cy - radius, radius * 2.0, radius * 2.0))
}

private func ellipseBounds(ellipse: SvgEllipse): ?SvgBounds {
    let rx = match (ellipse.rx) {
        case Some(value) => value.value
        case None => return None
    }
    let ry = match (ellipse.ry) {
        case Some(value) => value.value
        case None => return None
    }
    if (rx < 0.0 || ry < 0.0) {
        return None
    }
    let cx = lengthOrZero(ellipse.cx)
    let cy = lengthOrZero(ellipse.cy)
    Some(SvgBounds(cx - rx, cy - ry, rx * 2.0, ry * 2.0))
}

private func lineBounds(line: SvgLine): ?SvgBounds {
    let x1 = lengthOrZero(line.x1)
    let y1 = lengthOrZero(line.y1)
    let x2 = lengthOrZero(line.x2)
    let y2 = lengthOrZero(line.y2)
    Some(pointPairBounds(x1, y1, x2, y2))
}

private func pointsBounds(points: ?SvgPointList): ?SvgBounds {
    match (points) {
        case Some(list) =>
            if (list.points.size == 0) {
                return None
            }
            var minX = list.points[0].x
            var maxX = minX
            var minY = list.points[0].y
            var maxY = minY
            for (point in list.points) {
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
            Some(SvgBounds(minX, minY, maxX - minX, maxY - minY))
        case None => None
    }
}

private func pointPairBounds(x1: Float64, y1: Float64, x2: Float64, y2: Float64): SvgBounds {
    let minX = if (x1 < x2) { x1 } else { x2 }
    let maxX = if (x1 > x2) { x1 } else { x2 }
    let minY = if (y1 < y2) { y1 } else { y2 }
    let maxY = if (y1 > y2) { y1 } else { y2 }
    SvgBounds(minX, minY, maxX - minX, maxY - minY)
}

internal func lengthOrZero(length: ?SvgLength): Float64 {
    match (length) {
        case Some(value) => value.value
        case None => 0.0
    }
}
