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

/** 每个元素最多派生的 marker 数。 */
internal let SVG_MAX_MARKERS_PER_ELEMENT: Int64 = 1024
/** marker 引用链深度上限。 */
internal let SVG_MAX_MARKER_DEPTH: Int64 = 64

/** 一个 marker 实例：marker 元素 + 用户空间变换。 */
public class SvgMarkerInstance {
    public let marker: SvgMarker
    public let matrix: SvgMatrix
    /** 视口（markerWidth × markerHeight）到用户空间的矩阵，用于 overflow 裁剪。 */
    public let viewportMatrix: SvgMatrix
    public let viewportWidth: Float64
    public let viewportHeight: Float64

    internal init(
        marker: SvgMarker,
        matrix: SvgMatrix,
        viewportMatrix: SvgMatrix,
        viewportWidth: Float64,
        viewportHeight: Float64
    ) {
        this.marker = marker
        this.matrix = matrix
        this.viewportMatrix = viewportMatrix
        this.viewportWidth = viewportWidth
        this.viewportHeight = viewportHeight
    }
}

/**
 * 从 `path` / `line` / `polyline` / `polygon` 的顶点派生 marker 实例。
 *
 * 顶点取元素本地用户坐标；`markerUnits=strokeWidth` 时按元素 `stroke-width` 缩放，
 * `refX` / `refY` 对齐内容原点，`viewBox` 复用 `toMatrix`。
 */
public class SvgMarkerExpander {
    public let warnings = ArrayList<String>()
    private let root: ?SvgElement

    public init(root!: ?SvgElement = None) {
        this.root = root
    }

    public func expand(shape: SvgShape, style: SvgComputedStyle): Array<SvgMarkerInstance> {
        let contours = this.shapeContours(shape)
        let result = ArrayList<SvgMarkerInstance>()
        for (contour in contours) {
            if (contour.size == 0) {
                continue
            }
            let closed = (shape is SvgPolygon) ||
                (contour.size > 1 && sameSvgPoint(contour[0], contour[contour.size - 1]))
            let unique = if (closed && contour.size > 1 &&
                sameSvgPoint(contour[0], contour[contour.size - 1])) {
                contour[0..contour.size - 1]
            } else {
                contour
            }
            if (unique.size == 0) {
                continue
            }
            this.appendMarkers(
                result,
                style.get("marker-start"),
                [unique[0]],
                [startAngle(unique)],
                style,
                shape,
                true
            )
            let midPoints = ArrayList<SvgPoint>()
            let midAngles = ArrayList<Float64>()
            if (unique.size > 2) {
                var index = 1
                while (index < unique.size - 1) {
                    midPoints.add(unique[index])
                    midAngles.add(midAngle(unique, index, closed))
                    index++
                }
                if (closed) {
                    midPoints.add(unique[unique.size - 1])
                    midAngles.add(midAngle(unique, unique.size - 1, true))
                }
            }
            this.appendMarkers(
                result,
                style.get("marker-mid"),
                midPoints.toArray(),
                midAngles.toArray(),
                style,
                shape,
                false
            )
            let end = if (closed) {
                unique[0]
            } else {
                unique[unique.size - 1]
            }
            this.appendMarkers(
                result,
                style.get("marker-end"),
                [end],
                [endAngle(unique, closed)],
                style,
                shape,
                false
            )
        }
        result.toArray()
    }

    private func appendMarkers(
        result: ArrayList<SvgMarkerInstance>,
        reference: ?String,
        points: Array<SvgPoint>,
        tangents: Array<Float64>,
        style: SvgComputedStyle,
        shape: SvgShape,
        isStart: Bool
    ): Unit {
        if (points.size == 0) {
            return
        }
        let id = match (reference) {
            case Some(value) => markerIdOf(value)
            case None => return
        }
        let idValue = match (id) {
            case Some(value) => value
            case None => return
        }
        let marker = match (this.resolveMarker(idValue)) {
            case Some(value) => value
            case None =>
                this.warnings.add("marker 引用「#${idValue}」不存在")
                return
        }
        var index = 0
        while (index < points.size) {
            if (Int64(result.size) >= SVG_MAX_MARKERS_PER_ELEMENT) {
                this.warnings.add(
                    "元素「${shape.tag}」派生 marker 超过 ${SVG_MAX_MARKERS_PER_ELEMENT} 个，已截断"
                )
                return
            }
            var angle = match (marker.orient) {
                case Auto => tangents[index]
                case AutoStartReverse => if (isStart) {
                    tangents[index] + 180.0
                } else {
                    tangents[index]
                }
                case Angle(fixed) => fixed
            }
            let viewportMatrix = markerViewportMatrix(marker, points[index], angle, style)
            result.add(
                SvgMarkerInstance(
                    marker,
                    markerContentMatrix(marker, viewportMatrix),
                    viewportMatrix,
                    markerWidth(marker),
                    markerHeight(marker)
                )
            )
            index++
        }
    }

    private func resolveMarker(id: String): ?SvgMarker {
        var current = match (findSvgElementById(this.root, id)) {
            case Some(element) =>
                match (element) {
                    case marker: SvgMarker => marker
                    case _ => return None
                }
            case None => return None
        }
        let visited = ArrayList<Int64>()
        var depth: Int64 = 0
        while (true) {
            var repeated = false
            for (identity in visited) {
                if (identity == current.identity) {
                    repeated = true
                }
            }
            if (repeated) {
                this.warnings.add("marker 引用存在循环，已停止展开")
                break
            }
            visited.add(current.identity)
            if (depth > SVG_MAX_MARKER_DEPTH) {
                throw SvgException(
                    "marker 引用深度超过上限 ${SVG_MAX_MARKER_DEPTH}",
                    kind: SvgErrorKind.Limit
                )
            }
            let href = match (readSvgHref(current)) {
                case Some(value) => value
                case None => break
            }
            let nextId = stripSvgHash(href)
            let next = match (findSvgElementById(this.root, nextId)) {
                case Some(element) => element
                case None =>
                    this.warnings.add("marker 引用的「${nextId}」不存在")
                    break
            }
            match (next) {
                case marker: SvgMarker =>
                    current = marker
                    depth++
                case _ => break
            }
        }
        current
    }

    private func shapeContours(shape: SvgShape): Array<Array<SvgPoint>> {
        match (shape) {
            case line: SvgLine =>
                let x1 = (line.x1 ?? SvgLength(0.0)).value
                let y1 = (line.y1 ?? SvgLength(0.0)).value
                let x2 = (line.x2 ?? SvgLength(0.0)).value
                let y2 = (line.y2 ?? SvgLength(0.0)).value
                return [[SvgPoint(x1, y1), SvgPoint(x2, y2)]]
            case polyline: SvgPolyline =>
                return match (polyline.points) {
                    case Some(value) => [value.points]
                    case None => Array<Array<SvgPoint>>()
                }
            case polygon: SvgPolygon =>
                return match (polygon.points) {
                    case Some(value) => [value.points]
                    case None => Array<Array<SvgPoint>>()
                }
            case path: SvgPath =>
                let data = match (path.d) {
                    case Some(value) => value
                    case None => return Array<Array<SvgPoint>>()
                }
                let contours = flattenPathData(data, SvgMatrix.identity, 0.25)
                let result = ArrayList<Array<SvgPoint>>()
                for (contour in contours) {
                    if (contour.size > 0) {
                        result.add(contour)
                    }
                }
                return result.toArray()
            case _ => return Array<Array<SvgPoint>>()
        }
    }
}

private func sameSvgPoint(left: SvgPoint, right: SvgPoint): Bool {
    abs(left.x - right.x) < 1e-9 && abs(left.y - right.y) < 1e-9
}

private func startAngle(points: Array<SvgPoint>): Float64 {
    var index = 0
    while (index + 1 < points.size) {
        let dx = points[index + 1].x - points[0].x
        let dy = points[index + 1].y - points[0].y
        if (abs(dx) > 1e-9 || abs(dy) > 1e-9) {
            return atan2(dy, dx) * 180.0 / 3.141592653589793
        }
        index++
    }
    0.0
}

private func endAngle(points: Array<SvgPoint>, closed: Bool): Float64 {
    if (closed) {
        if (points.size < 2) {
            return 0.0
        }
        let dx = points[0].x - points[points.size - 1].x
        let dy = points[0].y - points[points.size - 1].y
        return atan2(dy, dx) * 180.0 / 3.141592653589793
    }
    var index = points.size - 1
    while (index > 0) {
        let dx = points[index].x - points[index - 1].x
        let dy = points[index].y - points[index - 1].y
        if (abs(dx) > 1e-9 || abs(dy) > 1e-9) {
            return atan2(dy, dx) * 180.0 / 3.141592653589793
        }
        index--
    }
    0.0
}

private func midAngle(points: Array<SvgPoint>, index: Int64, closed: Bool): Float64 {
    let previous = if (index > 0) {
        points[index - 1]
    } else {
        points[points.size - 1]
    }
    let next = if (index + 1 < points.size) {
        points[index + 1]
    } else if (closed) {
        points[0]
    } else {
        points[points.size - 1]
    }
    atan2(next.y - previous.y, next.x - previous.x) * 180.0 / 3.141592653589793
}

private func markerIdOf(text: String): ?String {
    let trimmed = text.trimAscii()
    if (trimmed.size < 5 || trimmed[0..4] != "url(") {
        return None
    }
    let close = indexOfSvgByte(trimmed, b')')
    if (close < 0) {
        return None
    }
    var inner = trimmed[4..close].trimAscii()
    inner = trimAsciiQuotes(inner)
    if (inner.size > 0 && inner[0] == b'#') {
        inner = inner[1..]
    }
    if (inner.size == 0) {
        None
    } else {
        Some(inner)
    }
}

private func markerUnitScale(marker: SvgMarker, style: SvgComputedStyle): Float64 {
    if (marker.markerUnits == SvgMarkerUnits.StrokeWidth) {
        let width = style.strokeWidth().value
        if (width > 0.0) {
            return width
        }
        return 1.0
    }
    1.0
}

private func markerWidth(marker: SvgMarker): Float64 {
    (marker.markerWidth ?? SvgLength(3.0)).value
}

private func markerHeight(marker: SvgMarker): Float64 {
    (marker.markerHeight ?? SvgLength(3.0)).value
}

/** 视口坐标 → 用户空间；不包含 viewBox 内容映射与 refX/refY 平移。 */
private func markerViewportMatrix(
    marker: SvgMarker,
    vertex: SvgPoint,
    angle: Float64,
    style: SvgComputedStyle
): SvgMatrix {
    let unitScale = markerUnitScale(marker, style)
    SvgMatrix.translate(vertex.x, vertex.y)
        .multiply(SvgMatrix.rotate(angle))
        .multiply(SvgMatrix.scale(unitScale, unitScale))
}

/** 内容坐标（viewBox）→ 视口坐标；无 viewBox 时为恒等。 */
internal func markerViewBoxMatrix(marker: SvgMarker): SvgMatrix {
    match (marker.viewBox) {
        case Some(box) =>
            marker.preserveAspectRatio.toMatrix(box, markerWidth(marker), markerHeight(marker))
        case None => SvgMatrix.identity
    }
}

/** 内容坐标（viewBox / marker 用户坐标）→ 用户空间。 */
private func markerContentMatrix(marker: SvgMarker, viewportMatrix: SvgMatrix): SvgMatrix {
    let content = markerViewBoxMatrix(marker)
    let referenceX = (marker.refX ?? SvgLength(0.0)).value
    let referenceY = (marker.refY ?? SvgLength(0.0)).value
    viewportMatrix
        .multiply(content)
        .multiply(SvgMatrix.translate(-referenceX, -referenceY))
}
