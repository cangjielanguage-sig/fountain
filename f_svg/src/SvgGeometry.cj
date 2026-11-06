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

private let SVG_GEOM_PI = 3.141592653589793
private let SVG_GEOM_EPSILON = 1e-12

/**
 * 几何包围盒计算。
 *
 * 路径用解析极值（贝塞尔导数零点、弧中心参数化）而不是扁平化采样；
 * 描边在几何盒外扩 `stroke-width/2`，miter join 再纳入受 `miterlimit` 约束的尖角。
 */
public class SvgGeometry {
    /** 元素自身坐标系中的几何包围盒（不含描边）。文本需 `fonts` 提供字体。 */
    public static func bounds(
        element: SvgElement,
        style!: SvgComputedStyle,
        fonts!: ?SvgFontRegistry = None,
        styles!: ?SvgComputedStyleTree = None
    ): ?SvgBounds {
        match (element) {
            case rect: SvgRect => return rectBounds(rect, style)
            case circle: SvgCircle => return circleBounds(circle, style)
            case ellipse: SvgEllipse => return ellipseBounds(ellipse, style)
            case line: SvgLine => return lineBounds(line, style)
            case polyline: SvgPolyline => return pointsBounds(polyline.points)
            case polygon: SvgPolygon => return pointsBounds(polygon.points)
            case path: SvgPath => return pathElementBounds(path)
            case text: SvgTextElement => return textElementBounds(text, style, fonts, styles)
            case _ => ()
        }
        None
    }

    /** 含描边的包围盒。 */
    public static func strokeBounds(
        element: SvgElement,
        style!: SvgComputedStyle,
        fonts!: ?SvgFontRegistry = None
    ): ?SvgBounds {
        let base = match (bounds(element, style: style, fonts: fonts)) {
            case Some(box) => box
            case None => return None
        }
        if (style.stroke().kind == SvgPaintKind.None) {
            return Some(base)
        }
        let width = style.strokeWidth().value
        if (width <= 0.0) {
            return Some(base)
        }
        let half = width / 2.0
        var result = base.inflate(half)
        if (style.strokeLineJoin() == SvgLineJoin.Miter) {
            let limit = style.strokeMiterLimit()
            for (tip in miterTips(element, half, limit)) {
                result = result.union(SvgBounds(tip.x, tip.y, 0.0, 0.0))
            }
        }
        Some(result)
    }

    /** 应用元素及其祖先 `transform` 后的包围盒。 */
    public static func absoluteBounds(
        element: SvgElement,
        style!: SvgComputedStyle,
        fonts!: ?SvgFontRegistry = None,
        styles!: ?SvgComputedStyleTree = None,
        viewportWidth!: Float64 = 300.0,
        viewportHeight!: Float64 = 150.0
    ): ?SvgBounds {
        let base = match (bounds(element, style: style, fonts: fonts)) {
            case Some(box) => box
            case None => return None
        }
        Some(base.transform(
            ancestorTransform(
                element,
                styles: styles,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight
            )
        ))
    }

    /**
     * 渲染阶段使用的绘制包围盒。
     *
     * 与公开 `bounds` 的唯一区别：文本缺字时仍返回占位字形布局的包围盒，
     * 避免滤镜 / 蒙版区域退化为空导致整段文本消失。公开 `bounds` 的契约不变。
     * 文本的装饰线不并入此包围盒；`objectBoundingBox` 渐变仍需按字形布局范围取样。
     */
    internal static func renderBounds(
        element: SvgElement,
        style!: SvgComputedStyle,
        fonts!: ?SvgFontRegistry = None,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None,
        layoutCache!: ?SvgTextLayoutCache = None
    ): ?SvgBounds {
        match (element) {
            case text: SvgTextElement =>
                let registry = match (fonts) {
                    case Some(value) => value
                    case None => SvgFontRegistry.defaultRegistry()
                }
                let renderer = SvgTextRenderer(registry: registry, layoutCache: layoutCache)
                renderer.layout(text, style: style, root: root, styles: styles).bounds
            case _ => bounds(element, style: style, fonts: fonts, styles: styles)
        }
    }

    /**
     * 渲染阶段的裁剪 / 滤镜包围盒：在绘制包围盒基础上并入文本装饰线。
     *
     * 装饰线在基线之外，若不并入会让裁剪快路径漏裁下划线 / 上划线 / 删除线。
     */
    internal static func renderClipBounds(
        element: SvgElement,
        style!: SvgComputedStyle,
        fonts!: ?SvgFontRegistry = None,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None,
        layoutCache!: ?SvgTextLayoutCache = None
    ): ?SvgBounds {
        match (element) {
            case text: SvgTextElement =>
                let registry = match (fonts) {
                    case Some(value) => value
                    case None => SvgFontRegistry.defaultRegistry()
                }
                let renderer = SvgTextRenderer(registry: registry, layoutCache: layoutCache)
                var bounds = renderer.layout(text, style: style, root: root, styles: styles).bounds
                // 装饰线在基线之外，必须并入裁剪包围盒，否则裁剪快路径会漏裁。
                if (renderer.hasDecoration(text, style: style, root: root, styles: styles)) {
                    match (renderer.decorationOutline(
                        text,
                        style: style,
                        root: root,
                        styles: styles
                    )) {
                        case Some(path) =>
                            match (pathDataBounds(path)) {
                                case Some(decoration) =>
                                    bounds = match (bounds) {
                                        case Some(existing) => Some(existing.union(decoration))
                                        case None => Some(decoration)
                                    }
                                case None => ()
                            }
                        case None => ()
                    }
                }
                bounds
            case _ => renderBounds(
                element,
                style: style,
                fonts: fonts,
                styles: styles,
                layoutCache: layoutCache
            )
        }
    }

    /**
     * 元素局部坐标到根用户空间的矩阵。
     *
     * 包含各级 `transform` 与嵌套 `svg` 的 `viewBox` / `preserveAspectRatio`；
     * 不包含根 `viewBox` 与 `use` 实例化产生的变换。
     */
    public static func ctm(
        element: SvgElement,
        styles!: ?SvgComputedStyleTree = None,
        viewportWidth!: ?Float64 = None,
        viewportHeight!: ?Float64 = None
    ): SvgMatrix {
        let chain = ArrayList<SvgElement>()
        var current: ?SvgElement = Some(element)
        while (true) {
            match (current) {
                case Some(node) =>
                    chain.add(node)
                    current = node.parent
                case None => break
            }
        }
        if (chain.size == 0) {
            return SvgMatrix.identity
        }
        let top = chain[chain.size - 1]
        let root = match (top) {
            case value: SvgRoot => value
            case _ => return SvgMatrix.identity
        }
        let viewport = SvgViewport.from(
            root,
            viewportWidth ?? 300.0,
            viewportHeight ?? 150.0
        )
        var width = viewport.width
        var height = viewport.height
        var matrix = SvgMatrix.identity
        var index = chain.size - 1
        while (index >= 0) {
            let node = chain[index]
            if (node == root) {
                matrix = matrix.multiply(elementMatrix(node, styles, width, height))
            } else {
                match (node) {
                    case nested: SvgRoot =>
                        matrix = SvgViewport.nestedTransform(matrix, nested, width, height)
                            .multiply(elementMatrix(nested, styles, width, height))
                        let nestedViewport = SvgViewport.nestedViewport(nested, width, height)
                        width = nestedViewport.width
                        height = nestedViewport.height
                    case _ =>
                        matrix = matrix.multiply(elementMatrix(node, styles, width, height))
                }
            }
            index--
        }
        matrix
    }

    /** `scale(dpr) × viewport.matrix × ctm(element)`，与渲染器的设备矩阵顺序一致。 */
    public static func screenCTM(
        element: SvgElement,
        viewport: SvgViewportTransform,
        styles!: ?SvgComputedStyleTree = None
    ): SvgMatrix {
        SvgMatrix.scale(viewport.devicePixelRatio, viewport.devicePixelRatio)
            .multiply(viewport.matrix)
            .multiply(ctm(element, styles: styles))
    }
}

/** 优先读取计算样式中的长度；未声明或不可解析时回退元素属性。 */
internal func svgStyledLength(
    style: ?SvgComputedStyle,
    name: String,
    fallback: ?SvgLength
): ?SvgLength {
    match (style) {
        case Some(value) =>
            if (value.sourceOf(name) == CssStyleSource.Default) {
                return fallback
            }
            match (value.get(name)) {
                case Some(text) =>
                    match (SvgLength.tryParse(text)) {
                        case Some(length) => return Some(length)
                        case None => return fallback
                    }
                case None => return fallback
            }
        case None => fallback
    }
}

private func rectBounds(rect: SvgRect, style: ?SvgComputedStyle): ?SvgBounds {
    let width = match (svgStyledLength(style, "width", rect.width)) {
        case Some(value) => value.value
        case None => return None
    }
    let height = match (svgStyledLength(style, "height", rect.height)) {
        case Some(value) => value.value
        case None => return None
    }
    if (width < 0.0 || height < 0.0) {
        return None
    }
    let x = lengthOrZero(svgStyledLength(style, "x", rect.x))
    let y = lengthOrZero(svgStyledLength(style, "y", rect.y))
    Some(SvgBounds(x, y, width, height))
}

private func circleBounds(circle: SvgCircle, style: ?SvgComputedStyle): ?SvgBounds {
    let radius = match (svgStyledLength(style, "r", circle.r)) {
        case Some(value) => value.value
        case None => return None
    }
    if (radius < 0.0) {
        return None
    }
    let cx = lengthOrZero(svgStyledLength(style, "cx", circle.cx))
    let cy = lengthOrZero(svgStyledLength(style, "cy", circle.cy))
    Some(SvgBounds(cx - radius, cy - radius, radius * 2.0, radius * 2.0))
}

private func ellipseBounds(ellipse: SvgEllipse, style: ?SvgComputedStyle): ?SvgBounds {
    let rx = match (svgStyledLength(style, "rx", ellipse.rx)) {
        case Some(value) => value.value
        case None => return None
    }
    let ry = match (svgStyledLength(style, "ry", ellipse.ry)) {
        case Some(value) => value.value
        case None => return None
    }
    if (rx < 0.0 || ry < 0.0) {
        return None
    }
    let cx = lengthOrZero(svgStyledLength(style, "cx", ellipse.cx))
    let cy = lengthOrZero(svgStyledLength(style, "cy", ellipse.cy))
    Some(SvgBounds(cx - rx, cy - ry, rx * 2.0, ry * 2.0))
}

private func lineBounds(line: SvgLine, style: ?SvgComputedStyle): ?SvgBounds {
    let x1 = lengthOrZero(svgStyledLength(style, "x1", line.x1))
    let y1 = lengthOrZero(svgStyledLength(style, "y1", line.y1))
    let x2 = lengthOrZero(svgStyledLength(style, "x2", line.x2))
    let y2 = lengthOrZero(svgStyledLength(style, "y2", line.y2))
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

private func pathElementBounds(path: SvgPath): ?SvgBounds {
    match (path.d) {
        case Some(data) => pathDataBounds(data)
        case None => None
    }
}

private class SvgBoundsAccumulator {
    var box = SvgBounds.empty()
    var hasAny = false

    func addPoint(x: Float64, y: Float64): Unit {
        if (!isFiniteSvgNumber(x) || !isFiniteSvgNumber(y)) {
            return
        }
        this.box = this.box.union(SvgBounds(x, y, 0.0, 0.0))
        this.hasAny = true
    }

    func addBox(box: SvgBounds): Unit {
        if (box.isEmpty()) {
            return
        }
        this.box = this.box.union(box)
        this.hasAny = true
    }
}

internal func isFiniteSvgNumber(value: Float64): Bool {
    !value.isNaN() && !value.isInf()
}

/**
 * 路径包围盒：遍历绝对化命令，`H/V` 已由 `toAbsolute` 转成 `L`，
 * `S/T` 的隐式控制点在此推导。
 */
internal func pathDataBounds(data: SvgPathData): ?SvgBounds {
    let absolute = data.toAbsolute()
    let acc = SvgBoundsAccumulator()
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

    for (command in absolute.commands) {
        match (command.kind) {
            case MoveTo =>
                let x = command.values[0]
                let y = command.values[1]
                if (isFiniteSvgNumber(x) && isFiniteSvgNumber(y)) {
                    acc.addPoint(x, y)
                    currentX = x
                    currentY = y
                    startX = x
                    startY = y
                }
                hasCubic = false
                hasQuad = false
            case LineTo =>
                let x = command.values[0]
                let y = command.values[1]
                if (isFiniteSvgNumber(x) && isFiniteSvgNumber(y)) {
                    acc.addPoint(x, y)
                    currentX = x
                    currentY = y
                }
                hasCubic = false
                hasQuad = false
            case CurveTo =>
                let c1x = command.values[0]
                let c1y = command.values[1]
                let c2x = command.values[2]
                let c2y = command.values[3]
                let x = command.values[4]
                let y = command.values[5]
                if (allFinite([c1x, c1y, c2x, c2y, x, y])) {
                    acc.addBox(cubicBounds(currentX, currentY, c1x, c1y, c2x, c2y, x, y))
                    currentX = x
                    currentY = y
                    lastCubicX = c2x
                    lastCubicY = c2y
                    hasCubic = true
                }
                hasQuad = false
            case SmoothCurveTo =>
                let c1x = if (hasCubic) { 2.0 * currentX - lastCubicX } else { currentX }
                let c1y = if (hasCubic) { 2.0 * currentY - lastCubicY } else { currentY }
                let c2x = command.values[0]
                let c2y = command.values[1]
                let x = command.values[2]
                let y = command.values[3]
                if (allFinite([c1x, c1y, c2x, c2y, x, y])) {
                    acc.addBox(cubicBounds(currentX, currentY, c1x, c1y, c2x, c2y, x, y))
                    currentX = x
                    currentY = y
                    lastCubicX = c2x
                    lastCubicY = c2y
                    hasCubic = true
                }
                hasQuad = false
            case QuadraticBezierTo =>
                let ctrlX = command.values[0]
                let ctrlY = command.values[1]
                let x = command.values[2]
                let y = command.values[3]
                if (allFinite([ctrlX, ctrlY, x, y])) {
                    acc.addBox(quadraticBounds(currentX, currentY, ctrlX, ctrlY, x, y))
                    currentX = x
                    currentY = y
                    lastQuadX = ctrlX
                    lastQuadY = ctrlY
                    hasQuad = true
                }
                hasCubic = false
            case SmoothQuadraticBezierTo =>
                let ctrlX = if (hasQuad) { 2.0 * currentX - lastQuadX } else { currentX }
                let ctrlY = if (hasQuad) { 2.0 * currentY - lastQuadY } else { currentY }
                let x = command.values[0]
                let y = command.values[1]
                if (allFinite([ctrlX, ctrlY, x, y])) {
                    acc.addBox(quadraticBounds(currentX, currentY, ctrlX, ctrlY, x, y))
                    currentX = x
                    currentY = y
                    lastQuadX = ctrlX
                    lastQuadY = ctrlY
                    hasQuad = true
                }
                hasCubic = false
            case ArcTo =>
                let rx = command.values[0]
                let ry = command.values[1]
                let rotation = command.values[2]
                let large = command.values[3] != 0.0
                let sweep = command.values[4] != 0.0
                let x = command.values[5]
                let y = command.values[6]
                if (allFinite([rx, ry, rotation, x, y])) {
                    acc.addBox(
                        arcBounds(currentX, currentY, rx, ry, rotation, large, sweep, x, y)
                    )
                    currentX = x
                    currentY = y
                }
                hasCubic = false
                hasQuad = false
            case ClosePath =>
                acc.addPoint(startX, startY)
                currentX = startX
                currentY = startY
                hasCubic = false
                hasQuad = false
            case _ => ()
        }
    }
    if (acc.hasAny) {
        Some(acc.box)
    } else {
        None
    }
}

private func allFinite(values: Array<Float64>): Bool {
    for (value in values) {
        if (!isFiniteSvgNumber(value)) {
            return false
        }
    }
    true
}

private func cubicBounds(
    x0: Float64,
    y0: Float64,
    x1: Float64,
    y1: Float64,
    x2: Float64,
    y2: Float64,
    x3: Float64,
    y3: Float64
): SvgBounds {
    var box = SvgBounds(x0, y0, 0.0, 0.0)
    box = box.union(SvgBounds(x3, y3, 0.0, 0.0))
    let xRoots = cubicDerivativeRoots(x0, x1, x2, x3)
    for (t in xRoots) {
        box = box.union(SvgBounds(cubicAt(x0, x1, x2, x3, t), cubicAt(y0, y1, y2, y3, t), 0.0, 0.0))
    }
    let yRoots = cubicDerivativeRoots(y0, y1, y2, y3)
    for (t in yRoots) {
        box = box.union(SvgBounds(cubicAt(x0, x1, x2, x3, t), cubicAt(y0, y1, y2, y3, t), 0.0, 0.0))
    }
    box
}

private func cubicAt(p0: Float64, p1: Float64, p2: Float64, p3: Float64, t: Float64): Float64 {
    let mt = 1.0 - t
    mt * mt * mt * p0 + 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t * p3
}

/** 解 `B'(t)=0`，返回 `(0,1)` 内的根。 */
private func cubicDerivativeRoots(p0: Float64, p1: Float64, p2: Float64, p3: Float64): Array<Float64> {
    let a = 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3)
    let b = 6.0 * (p0 - 2.0 * p1 + p2)
    let c = 3.0 * (p1 - p0)
    quadraticRootsInUnit(a, b, c)
}

private func quadraticRootsInUnit(a: Float64, b: Float64, c: Float64): Array<Float64> {
    let roots = ArrayList<Float64>()
    if (abs(a) < SVG_GEOM_EPSILON) {
        if (abs(b) >= SVG_GEOM_EPSILON) {
            let t = -c / b
            if (t > 0.0 && t < 1.0) {
                roots.add(t)
            }
        }
    } else {
        let discriminant = b * b - 4.0 * a * c
        if (discriminant >= 0.0) {
            let root = sqrt(discriminant)
            let t1 = (-b + root) / (2.0 * a)
            let t2 = (-b - root) / (2.0 * a)
            if (t1 > 0.0 && t1 < 1.0) {
                roots.add(t1)
            }
            if (t2 > 0.0 && t2 < 1.0) {
                roots.add(t2)
            }
        }
    }
    roots.toArray()
}

private func quadraticBounds(
    x0: Float64,
    y0: Float64,
    x1: Float64,
    y1: Float64,
    x2: Float64,
    y2: Float64
): SvgBounds {
    var box = SvgBounds(x0, y0, 0.0, 0.0)
    box = box.union(SvgBounds(x2, y2, 0.0, 0.0))
    let denomX = x0 - 2.0 * x1 + x2
    if (abs(denomX) > SVG_GEOM_EPSILON) {
        let t = (x0 - x1) / denomX
        if (t > 0.0 && t < 1.0) {
            box = box.union(SvgBounds(quadraticAt(x0, x1, x2, t), quadraticAt(y0, y1, y2, t), 0.0, 0.0))
        }
    }
    let denomY = y0 - 2.0 * y1 + y2
    if (abs(denomY) > SVG_GEOM_EPSILON) {
        let t = (y0 - y1) / denomY
        if (t > 0.0 && t < 1.0) {
            box = box.union(SvgBounds(quadraticAt(x0, x1, x2, t), quadraticAt(y0, y1, y2, t), 0.0, 0.0))
        }
    }
    box
}

private func quadraticAt(p0: Float64, p1: Float64, p2: Float64, t: Float64): Float64 {
    let mt = 1.0 - t
    mt * mt * p0 + 2.0 * mt * t * p1 + t * t * p2
}

/** 端点参数 → 中心参数，取端点与落入扫描角范围的四个轴向极值。 */
private func arcBounds(
    x0: Float64,
    y0: Float64,
    rxIn: Float64,
    ryIn: Float64,
    rotationDegrees: Float64,
    large: Bool,
    sweep: Bool,
    x1: Float64,
    y1: Float64
): SvgBounds {
    let rx = abs(rxIn)
    let ry = abs(ryIn)
    var box = SvgBounds(x0, y0, 0.0, 0.0).union(SvgBounds(x1, y1, 0.0, 0.0))
    if (rx < SVG_GEOM_EPSILON || ry < SVG_GEOM_EPSILON) {
        return box
    }
    if (x0 == x1 && y0 == y1) {
        return box
    }
    let phi = rotationDegrees * SVG_GEOM_PI / 180.0
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (x0 - x1) / 2.0
    let dy = (y0 - y1) / 2.0
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    var adjustedRx = rx
    var adjustedRy = ry
    let lambda = x1p * x1p / (adjustedRx * adjustedRx) + y1p * y1p / (adjustedRy * adjustedRy)
    if (lambda > 1.0) {
        let scale = sqrt(lambda)
        adjustedRx = adjustedRx * scale
        adjustedRy = adjustedRy * scale
    }
    let sign = if (large == sweep) { -1.0 } else { 1.0 }
    let rx2 = adjustedRx * adjustedRx
    let ry2 = adjustedRy * adjustedRy
    let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
    let coefficient = if (denominator < SVG_GEOM_EPSILON) {
        0.0
    } else {
        sign * sqrt(if (numerator < 0.0) { 0.0 } else { numerator / denominator })
    }
    let cxp = coefficient * adjustedRx * y1p / adjustedRy
    let cyp = coefficient * -adjustedRy * x1p / adjustedRx
    let cx = cosPhi * cxp - sinPhi * cyp + (x0 + x1) / 2.0
    let cy = sinPhi * cxp + cosPhi * cyp + (y0 + y1) / 2.0

    let ux = (x1p - cxp) / adjustedRx
    let uy = (y1p - cyp) / adjustedRy
    let vx = (-x1p - cxp) / adjustedRx
    let vy = (-y1p - cyp) / adjustedRy
    let theta1 = atan2(uy, ux)
    var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    if (!sweep && delta > 0.0) {
        delta -= 2.0 * SVG_GEOM_PI
    } else if (sweep && delta < 0.0) {
        delta += 2.0 * SVG_GEOM_PI
    }
    let endAngle = theta1 + delta
    let low = if (theta1 < endAngle) { theta1 } else { endAngle }
    let high = if (theta1 < endAngle) { endAngle } else { theta1 }
    // 参数角处的 x / y 导数为零；对旋转椭圆也适用。
    let xExtremumAngle = atan2(-adjustedRy * sinPhi, adjustedRx * cosPhi)
    let yExtremumAngle = atan2(adjustedRy * cosPhi, adjustedRx * sinPhi)
    for (base in [xExtremumAngle, yExtremumAngle]) {
        for (offset in -4..=4) {
            let angle = base + Float64(offset) * SVG_GEOM_PI
            if (angle < low || angle > high) {
                continue
            }
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            let px = cx + adjustedRx * cosPhi * cosAngle - adjustedRy * sinPhi * sinAngle
            let py = cy + adjustedRx * sinPhi * cosAngle + adjustedRy * cosPhi * sinAngle
            box = box.union(SvgBounds(px, py, 0.0, 0.0))
        }
    }
    box
}

private class SvgPolylinePath {
    let points = ArrayList<SvgPoint>()
    var closed = false
}

/** 收集用于 miter 尖角计算的折线（曲线以端点近似）。 */
private func collectMiterPolylines(element: SvgElement): Array<SvgPolylinePath> {
    let result = ArrayList<SvgPolylinePath>()
    match (element) {
        case polyline: SvgPolyline =>
            match (polyline.points) {
                case Some(list) =>
                    let path = SvgPolylinePath()
                    for (point in list.points) {
                        path.points.add(point)
                    }
                    result.add(path)
                case None => ()
            }
        case polygon: SvgPolygon =>
            match (polygon.points) {
                case Some(list) =>
                    let path = SvgPolylinePath()
                    for (point in list.points) {
                        path.points.add(point)
                    }
                    path.closed = true
                    result.add(path)
                case None => ()
            }
        case rect: SvgRect =>
            match ((rect.width, rect.height)) {
                case (Some(width), Some(height)) =>
                    if (width.value > 0.0 && height.value > 0.0) {
                        let x = lengthOrZero(rect.x)
                        let y = lengthOrZero(rect.y)
                        let path = SvgPolylinePath()
                        path.points.add(SvgPoint(x, y))
                        path.points.add(SvgPoint(x + width.value, y))
                        path.points.add(SvgPoint(x + width.value, y + height.value))
                        path.points.add(SvgPoint(x, y + height.value))
                        path.closed = true
                        result.add(path)
                    }
                case _ => ()
            }
        case path: SvgPath =>
            match (path.d) {
                case Some(data) =>
                    let absolute = data.toAbsolute()
                    var current: ?SvgPolylinePath = None
                    var currentX = 0.0
                    var currentY = 0.0
                    var startX = 0.0
                    var startY = 0.0
                    for (command in absolute.commands) {
                        match (command.kind) {
                            case MoveTo =>
                                let next = SvgPolylinePath()
                                currentX = command.values[0]
                                currentY = command.values[1]
                                startX = currentX
                                startY = currentY
                                next.points.add(SvgPoint(currentX, currentY))
                                result.add(next)
                                current = Some(next)
                            case LineTo =>
                                currentX = command.values[0]
                                currentY = command.values[1]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case CurveTo =>
                                currentX = command.values[4]
                                currentY = command.values[5]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case SmoothCurveTo =>
                                currentX = command.values[2]
                                currentY = command.values[3]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case QuadraticBezierTo =>
                                currentX = command.values[2]
                                currentY = command.values[3]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case SmoothQuadraticBezierTo =>
                                currentX = command.values[0]
                                currentY = command.values[1]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case ArcTo =>
                                currentX = command.values[5]
                                currentY = command.values[6]
                                match (current) {
                                    case Some(line) => line.points.add(SvgPoint(currentX, currentY))
                                    case None => ()
                                }
                            case ClosePath =>
                                currentX = startX
                                currentY = startY
                                match (current) {
                                    case Some(line) =>
                                        line.closed = true
                                        line.points.add(SvgPoint(startX, startY))
                                    case None => ()
                                }
                            case _ => ()
                        }
                    }
                case None => ()
            }
        case _ => ()
    }
    result.toArray()
}

private func miterTips(element: SvgElement, half: Float64, limit: Float64): Array<SvgPoint> {
    let tips = ArrayList<SvgPoint>()
    for (line in collectMiterPolylines(element)) {
        let points = line.points
        if (points.size < 3) {
            continue
        }
        if (line.closed) {
            if (points[0] == points[points.size - 1]) {
                tipAt(points[points.size - 2], points[0], points[1], half, limit, tips)
            }
            for (index in 0..points.size) {
                let previous = points[(index - 1 + points.size) % points.size]
                let next = points[(index + 1) % points.size]
                tipAt(previous, points[index], next, half, limit, tips)
            }
        } else {
            for (index in 1..points.size - 1) {
                tipAt(points[index - 1], points[index], points[index + 1], half, limit, tips)
            }
        }
    }
    tips.toArray()
}

private func tipAt(
    previous: SvgPoint,
    vertex: SvgPoint,
    next: SvgPoint,
    half: Float64,
    limit: Float64,
    tips: ArrayList<SvgPoint>
): Unit {
    let v1x = vertex.x - previous.x
    let v1y = vertex.y - previous.y
    let v2x = next.x - vertex.x
    let v2y = next.y - vertex.y
    let length1 = sqrt(v1x * v1x + v1y * v1y)
    let length2 = sqrt(v2x * v2x + v2y * v2y)
    if (length1 < SVG_GEOM_EPSILON || length2 < SVG_GEOM_EPSILON) {
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
    let ratio = sqrt(2.0 / denominator)
    if (ratio > limit) {
        return
    }
    let cross = u1x * u2y - u1y * u2x
    let sign = if (cross > 0.0) { -1.0 } else { 1.0 }
    var dirX = sign * (-u1y + -u2y)
    var dirY = sign * (u1x + u2x)
    let dirLength = sqrt(dirX * dirX + dirY * dirY)
    if (dirLength < SVG_GEOM_EPSILON) {
        return
    }
    dirX = dirX / dirLength
    dirY = dirY / dirLength
    tips.add(SvgPoint(vertex.x + dirX * half * ratio, vertex.y + dirY * half * ratio))
}

private func elementMatrix(element: SvgElement): SvgMatrix {
    match (element.transform) {
        case Some(transform) => transform.toMatrix()
        case None => SvgMatrix.identity
    }
}

/** 带样式上下文的变换：解析 `transform-origin` / `transform-box`。 */
private func elementMatrix(
    element: SvgElement,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): SvgMatrix {
    if (styles.isNone()) {
        return elementMatrix(element)
    }
    let style = match (styles) {
        case Some(tree) => tree.get(element)
        case None => Option<SvgComputedStyle>.None
    }
    if (style.isNone()) {
        return elementMatrix(element)
    }
    let resolved = match (style) {
        case Some(value) => value
        case None => return elementMatrix(element)
    }
    var box: ?SvgBounds = Option<SvgBounds>.None
    if (resolved.transformBox() == SvgTransformBox.FillBox) {
        box = SvgGeometry.bounds(element, style: resolved)
    }
    effectiveElementTransform(
        element,
        style: Some(resolved),
        bounds: box,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight
    )
}


private func ancestorTransform(
    element: SvgElement,
    styles!: ?SvgComputedStyleTree = None,
    viewportWidth!: Float64 = 300.0,
    viewportHeight!: Float64 = 150.0
): SvgMatrix {
    let chain = ArrayList<SvgElement>()
    var current: ?SvgElement = Some(element)
    while (true) {
        match (current) {
            case Some(node) =>
                chain.add(node)
                current = node.parent
            case None => break
        }
    }
    var matrix = SvgMatrix.identity
    var index = chain.size - 1
    while (index >= 0) {
        matrix = matrix.multiply(
            elementMatrix(chain[index], styles, viewportWidth, viewportHeight)
        )
        index--
    }
    matrix
}

private func textElementBounds(
    text: SvgTextElement,
    style: SvgComputedStyle,
    fonts: ?SvgFontRegistry,
    styles: ?SvgComputedStyleTree
): ?SvgBounds {
    let registry = match (fonts) {
        case Some(value) => value
        case None => SvgFontRegistry.defaultRegistry()
    }
    let layout = SvgTextRenderer(registry: registry).layout(text, style: style, styles: styles)
    if (layout.missingGlyph) {
        return None
    }
    layout.bounds
}
