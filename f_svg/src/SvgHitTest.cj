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

/**
 * 静态交互状态：`:hover` 可命中多个 id，`:focus` 只命中第一个可解析的 id。
 *
 * 未提供任何 id 时两个伪类都永不匹配；无 id 的元素也永不匹配。
 */
public class SvgInteractionState <: ToString {
    public let hoveredIds: Array<String>
    public let focusedIds: Array<String>
    private let hoveredSet = HashMap<String, Bool>()
    private let focusedId: ?String

    public init(
        hoveredIds!: Array<String> = Array<String>(),
        focusedIds!: Array<String> = Array<String>(),
        root!: ?SvgElement = None
    ) {
        this.hoveredIds = hoveredIds
        this.focusedIds = focusedIds
        for (id in hoveredIds) {
            if (id.size > 0) {
                this.hoveredSet[id] = true
            }
        }
        this.focusedId = resolveSvgFocusedId(focusedIds, root)
    }

    public static func empty(): SvgInteractionState {
        SvgInteractionState()
    }

    internal func isHovered(id: ?String): Bool {
        match (id) {
            case Some(value) => if (value.size == 0) {
                false
            } else {
                this.hoveredSet.get(value) ?? false
            }
            case None => false
        }
    }

    internal func isFocused(id: ?String): Bool {
        let target = match (this.focusedId) {
            case Some(value) => value
            case None => return false
        }
        match (id) {
            case Some(value) => value.size > 0 && value == target
            case None => false
        }
    }

    public func toString(): String {
        "SvgInteractionState(hover=${this.hoveredIds.size}, focus=${this.focusedId ?? ""})"
    }
}

/** 按顺序取第一个可解析的 id；无根元素时取第一个非空 id。 */
private func resolveSvgFocusedId(focusedIds: Array<String>, root: ?SvgElement): ?String {
    match (root) {
        case Some(value) =>
            for (id in focusedIds) {
                if (id.size == 0) {
                    continue
                }
                if (findSvgElementById(Some(value), id).isSome()) {
                    return Some(id)
                }
            }
            None
        case None =>
            for (id in focusedIds) {
                if (id.size > 0) {
                    return Some(id)
                }
            }
            None
    }
}

private let SVG_HIT_TOLERANCE = 0.25
private let SVG_HIT_EPSILON = 1e-9

private class SvgHitContext {
    let styles: SvgComputedStyleTree
    let root: SvgElement
    let viewportWidth: Float64
    let viewportHeight: Float64
    let fonts: ?SvgFontRegistry
    let origin: SvgPoint
    let maxElements: Int64
    var visited: Int64 = 0

    init(
        styles: SvgComputedStyleTree,
        root: SvgElement,
        viewportWidth: Float64,
        viewportHeight: Float64,
        fonts: ?SvgFontRegistry,
        origin: SvgPoint,
        maxElements: Int64
    ) {
        this.styles = styles
        this.root = root
        this.viewportWidth = viewportWidth
        this.viewportHeight = viewportHeight
        this.fonts = fonts
        this.origin = origin
        this.maxElements = maxElements
    }
}

/**
 * 静态命中测试。
 *
 * 输入设备坐标，按 DPR 与根 `viewBox` 逆变换到根用户空间，再逐元素逆变换到局部坐标；
 * 返回自上而下（后绘制者在前）的命中链。`pointer-events: none` 连同子树退出。
 */
public class SvgHitTest {
    public let warnings = ArrayList<String>()

    public func hitTest(
        document: SvgDocument,
        point: SvgPoint,
        options!: SvgRenderOptions = SvgRenderOptions(),
        maxElements!: Int64 = 1_000_000
    ): Array<SvgElement> {
        this.hitTest(document.root, point, options: options, maxElements: maxElements)
    }

    public func hitTest(
        root: SvgElement,
        point: SvgPoint,
        options!: SvgRenderOptions = SvgRenderOptions(),
        maxElements!: Int64 = 1_000_000
    ): Array<SvgElement> {
        if (maxElements <= 0) {
            throw invalidValue("maxElements 必须为正")
        }
        let (logicalWidth, logicalHeight) = svgHitLogicalSize(root, options)
        let interaction = SvgInteractionState(
            hoveredIds: options.hoveredIds,
            focusedIds: options.focusedIds,
            root: Some(root)
        )
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(
            root,
            interaction: interaction,
            mediaWidth: logicalWidth,
            mediaHeight: logicalHeight
        )
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let origin = svgHitOrigin(root, point, options, logicalWidth, logicalHeight)
        svgHitCollect(
            root,
            origin,
            styles,
            logicalWidth,
            logicalHeight,
            options.fonts,
            maxElements
        ).toArray()
    }

    /**
     * 规格命中 API：设备坐标 + 显式视口与样式树。
     *
     * `point` 先按 `devicePixelRatio` 转为逻辑坐标，再乘视口矩阵的逆；返回绘制序从上到下。
     */
    public func elementsAt(
        root: SvgElement,
        point: SvgPoint,
        viewport: SvgViewport,
        styles: SvgComputedStyleTree,
        devicePixelRatio!: Float64 = 1.0,
        maxElements!: Int64 = 1_000_000,
        fonts!: ?SvgFontRegistry = None
    ): ArrayList<SvgElement> {
        if (maxElements <= 0) {
            throw invalidValue("maxElements 必须为正")
        }
        if (!isFiniteSvgNumber(devicePixelRatio) || devicePixelRatio <= 0.0) {
            throw invalidValue("devicePixelRatio 必须为正的有限数")
        }
        let logical = SvgPoint(point.x / devicePixelRatio, point.y / devicePixelRatio)
        let matrix = match (root) {
            case svg: SvgRoot => viewport.transform(svg)
            case _ => SvgMatrix.identity
        }
        let origin = match (matrix.invert()) {
            case Some(inverse) => inverse.apply(logical)
            case None => logical
        }
        svgHitCollect(
            root,
            origin,
            styles,
            viewport.width,
            viewport.height,
            fonts,
            maxElements
        )
    }

    /** 规格命中 API：返回 `elementsAt` 的首项，未命中为 `None`。 */
    public func elementAt(
        root: SvgElement,
        point: SvgPoint,
        viewport: SvgViewport,
        styles: SvgComputedStyleTree,
        devicePixelRatio!: Float64 = 1.0,
        maxElements!: Int64 = 1_000_000,
        fonts!: ?SvgFontRegistry = None
    ): ?SvgElement {
        let hits = this.elementsAt(
            root,
            point,
            viewport,
            styles,
            devicePixelRatio: devicePixelRatio,
            maxElements: maxElements,
            fonts: fonts
        )
        if (hits.size == 0) {
            return Option<SvgElement>.None
        }
        Some(hits[0])
    }
}

/** 命中核心：后绘制者优先，遍历子节点后判定自身。 */
private func svgHitCollect(
    root: SvgElement,
    origin: SvgPoint,
    styles: SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64,
    fonts: ?SvgFontRegistry,
    maxElements: Int64
): ArrayList<SvgElement> {
    let context = SvgHitContext(
        styles,
        root,
        viewportWidth,
        viewportHeight,
        fonts,
        origin,
        maxElements
    )
    let result = ArrayList<SvgElement>()
    var index = root.children.size - 1
    while (index >= 0) {
        match (root.children[index]) {
            case ElementNode(child) => svgHitWalk(child, context, result)
            case _ => ()
        }
        index--
    }
    result
}

/** 逻辑尺寸：显式 width/height 优先，否则取根视口。 */
private func svgHitLogicalSize(root: SvgElement, options: SvgRenderOptions): (Float64, Float64) {
    let viewport = match (root) {
        case svg: SvgRoot => SvgViewport.from(svg, 300.0, 150.0)
        case _ => SvgViewport(300.0, 150.0)
    }
    (
        if (options.width > 0) { Float64(options.width) } else { viewport.width },
        if (options.height > 0) { Float64(options.height) } else { viewport.height }
    )
}

/** 设备坐标 → 根用户空间：先除 DPR，再乘根视口矩阵的逆。 */
private func svgHitOrigin(
    root: SvgElement,
    point: SvgPoint,
    options: SvgRenderOptions,
    logicalWidth: Float64,
    logicalHeight: Float64
): SvgPoint {
    let ratio = options.devicePixelRatio
    let logical = SvgPoint(point.x / ratio, point.y / ratio)
    let matrix = match (root) {
        case svg: SvgRoot =>
            let viewport = SvgViewport.from(svg, logicalWidth, logicalHeight)
            viewport.transform(svg)
        case _ => SvgMatrix.identity
    }
    match (matrix.invert()) {
        case Some(inverse) => inverse.apply(logical)
        case None => logical
    }
}

/** 后绘制者在前：先逆序遍历子节点，再判定自身。 */
private func svgHitWalk(
    element: SvgElement,
    context: SvgHitContext,
    result: ArrayList<SvgElement>
): Unit {
    context.visited++
    if (context.visited > context.maxElements) {
        throw SvgException(
            "命中测试元素数超过上限 ${context.maxElements}",
            kind: SvgErrorKind.Limit
        )
    }
    let style = match (context.styles.get(element)) {
        case Some(value) => value
        case None => return
    }
    if (style.display() == "none") {
        return
    }
    let events = style.pointerEvents()
    if (events == SvgPointerEvents.None) {
        return
    }
    var index = element.children.size - 1
    while (index >= 0) {
        match (element.children[index]) {
            case ElementNode(child) => svgHitWalk(child, context, result)
            case _ => ()
        }
        index--
    }
    let local = svgHitLocalPoint(element, context.origin, context)
    if (svgHitElementMatches(element, style, events, local, context)) {
        result.add(element)
    }
}

/** 根用户空间点 → 元素局部坐标。 */
private func svgHitLocalPoint(element: SvgElement, origin: SvgPoint, context: SvgHitContext): SvgPoint {
    let ctm = SvgGeometry.ctm(
        element,
        styles: context.styles,
        viewportWidth: context.viewportWidth,
        viewportHeight: context.viewportHeight
    )
    match (ctm.invert()) {
        case Some(inverse) => inverse.apply(origin)
        case None => origin
    }
}

private func svgHitElementMatches(
    element: SvgElement,
    style: SvgComputedStyle,
    events: SvgPointerEvents,
    point: SvgPoint,
    context: SvgHitContext
): Bool {
    let hidden = style.visibility() == "hidden" || style.visibility() == "collapse"

    match (element) {
        case image: SvgImage =>
            if (events == SvgPointerEvents.All) {
                return svgHitImageContains(image, style, point)
            }
            if (events == SvgPointerEvents.BoundingBox) {
                return !hidden && svgHitImageContains(image, style, point)
            }
            if (hidden && svgHitRequiresVisible(events)) {
                return false
            }
            return svgHitImageContains(image, style, point)
        case _ => ()
    }

    match (element) {
        case container: SvgContainer =>
            if (events == SvgPointerEvents.All) {
                return svgHitBBoxContains(element, style, point, context)
            }
            if (events == SvgPointerEvents.BoundingBox) {
                return !hidden && svgHitBBoxContains(element, style, point, context)
            }
            return false
        case svg: SvgRoot =>
            if (events == SvgPointerEvents.All) {
                return svgHitBBoxContains(element, style, point, context)
            }
            if (events == SvgPointerEvents.BoundingBox) {
                return !hidden && svgHitBBoxContains(element, style, point, context)
            }
            return false
        case _ => ()
    }

    if (events == SvgPointerEvents.All) {
        return svgHitBBoxContains(element, style, point, context)
    }
    if (events == SvgPointerEvents.BoundingBox) {
        return !hidden && svgHitBBoxContains(element, style, point, context)
    }
    if (hidden && svgHitRequiresVisible(events)) {
        return false
    }

    let paintedFill = style.fill().kind != SvgPaintKind.None
    let paintedStroke = style.stroke().kind != SvgPaintKind.None && style.strokeWidth().value > 0.0
    let wantsFill = svgHitWantsFill(events, paintedFill)
    let wantsStroke = svgHitWantsStroke(events, paintedStroke)
    if (!wantsFill && !wantsStroke) {
        return false
    }

    if (element.tag == "text") {
        return svgHitText(element, style, wantsFill, wantsStroke, point, context)
    }
    let path = match (elementPathData(element, style: Some(style))) {
        case Some(value) => value
        case None => return false
    }
    let contours = flattenPathData(path, SvgMatrix.identity, SVG_HIT_TOLERANCE)
    if (wantsFill && svgPointInContours(contours, point, style.fillRule())) {
        return true
    }
    if (wantsStroke &&
        svgPointNearContours(
            contours,
            point,
            style.strokeWidth().value / 2.0,
            style.strokeLineCap()
        )) {
        return true
    }
    false
}

private func svgHitRequiresVisible(events: SvgPointerEvents): Bool {
    match (events) {
        case VisiblePainted | VisibleFill | VisibleStroke | Visible | Auto => true
        case _ => false
    }
}

private func svgHitWantsFill(events: SvgPointerEvents, painted: Bool): Bool {
    match (events) {
        case Fill | VisibleFill => true
        case Painted | VisiblePainted | Auto => painted
        case Visible => true
        case Stroke | VisibleStroke => false
        case _ => false
    }
}

private func svgHitWantsStroke(events: SvgPointerEvents, painted: Bool): Bool {
    match (events) {
        case Stroke | VisibleStroke => true
        case Painted | VisiblePainted | Auto => painted
        case Visible => true
        case Fill | VisibleFill => false
        case _ => false
    }
}

private func svgHitText(
    element: SvgElement,
    style: SvgComputedStyle,
    wantsFill: Bool,
    wantsStroke: Bool,
    point: SvgPoint,
    context: SvgHitContext
): Bool {
    let text = match (element) {
        case value: SvgTextElement => value
        case _ => return false
    }
    let registry = match (context.fonts) {
        case Some(value) => value
        case None => SvgFontRegistry.defaultRegistry()
    }
    let renderer = SvgTextRenderer(registry: registry, layoutCache: Option<SvgTextLayoutCache>.None)
    let path = renderer.outline(text, style: style, root: Some(context.root), styles: Some(context.styles))
    let outline = match (path) {
        case Some(value) => value
        case None => return svgHitBBoxContains(element, style, point, context)
    }
    let contours = flattenPathData(outline, SvgMatrix.identity, SVG_HIT_TOLERANCE)
    if (wantsFill && svgPointInContours(contours, point, style.fillRule())) {
        return true
    }
    if (wantsStroke &&
        svgPointNearContours(
            contours,
            point,
            style.strokeWidth().value / 2.0,
            style.strokeLineCap()
        )) {
        return true
    }
    svgHitBBoxContains(element, style, point, context)
}

private func svgHitBBoxContains(
    element: SvgElement,
    style: SvgComputedStyle,
    point: SvgPoint,
    context: SvgHitContext
): Bool {
    let box = match (element) {
        case image: SvgImage => svgHitImageBounds(image, style)
        case text: SvgTextElement => SvgGeometry.bounds(
            text,
            style: style,
            fonts: context.fonts,
            styles: Some(context.styles)
        )
        case container: SvgContainer => svgBBoxOf(
            container,
            SvgBBoxRequest(
                SvgBBoxOptions(fonts: context.fonts),
                Some(context.styles),
                viewportWidth: context.viewportWidth,
                viewportHeight: context.viewportHeight
            )
        )
        case svg: SvgRoot => svgBBoxOf(
            svg,
            SvgBBoxRequest(
                SvgBBoxOptions(fonts: context.fonts),
                Some(context.styles),
                viewportWidth: context.viewportWidth,
                viewportHeight: context.viewportHeight
            )
        )
        case _ => SvgGeometry.bounds(element, style: style, fonts: context.fonts, styles: Some(context.styles))
    }
    match (box) {
        case Some(value) => svgBoundsContainsPoint(value, point)
        case None => false
    }
}

private func svgHitImageBounds(image: SvgImage, style: SvgComputedStyle): ?SvgBounds {
    let x = lengthOrZero(svgStyledLength(Some(style), "x", image.x))
    let y = lengthOrZero(svgStyledLength(Some(style), "y", image.y))
    let width = lengthOrZero(svgStyledLength(Some(style), "width", image.width))
    let height = lengthOrZero(svgStyledLength(Some(style), "height", image.height))
    if (width < 0.0 || height < 0.0) {
        return Option<SvgBounds>.None
    }
    Some(SvgBounds(x, y, width, height))
}

private func svgHitImageContains(image: SvgImage, style: SvgComputedStyle, point: SvgPoint): Bool {
    match (svgHitImageBounds(image, style)) {
        case Some(box) => svgBoundsContainsPoint(box, point)
        case None => false
    }
}

private func svgBoundsContainsPoint(box: SvgBounds, point: SvgPoint): Bool {
    if (box.isEmpty()) {
        return false
    }
    box.x - SVG_HIT_EPSILON <= point.x && point.x <= box.x + box.width + SVG_HIT_EPSILON &&
    box.y - SVG_HIT_EPSILON <= point.y && point.y <= box.y + box.height + SVG_HIT_EPSILON
}

private func svgPointInContours(
    contours: Array<Array<SvgPoint>>,
    point: SvgPoint,
    rule: SvgFillRule
): Bool {
    var winding = 0
    var crossings = 0
    for (contour in contours) {
        if (contour.size == 0) {
            continue
        }
        for (index in 0..contour.size) {
            let a = contour[index]
            let b = contour[(index + 1) % contour.size]
            if (svgPointOnSegment(point, a, b)) {
                return true
            }
            if ((a.y > point.y) != (b.y > point.y)) {
                let intersectionX = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if (point.x < intersectionX) {
                    crossings++
                    winding += if (b.y > a.y) { 1 } else { -1 }
                }
            }
        }
    }
    match (rule) {
        case Evenodd => crossings % 2 != 0
        case Nonzero => winding != 0
    }
}

private func svgPointNearContours(
    contours: Array<Array<SvgPoint>>,
    point: SvgPoint,
    halfWidth: Float64,
    cap: SvgLineCap
): Bool {
    if (halfWidth <= 0.0) {
        return false
    }
    for (contour in contours) {
        if (contour.size == 1) {
            if (svgLineCapCoversPoint(contour[0], contour[0], point, halfWidth, cap)) {
                return true
            }
            continue
        }
        let closed = contour[0] == contour[contour.size - 1]
        for (index in 1..contour.size) {
            if (svgDistanceToSegment(point, contour[index - 1], contour[index]) <= halfWidth) {
                return true
            }
        }
        if (!closed) {
            if (svgLineCapCoversPoint(
                contour[0],
                contour[1],
                point,
                halfWidth,
                cap
            ) && svgDistanceToPoint(point, contour[0]) <= halfWidth) {
                return true
            }
            let last = contour.size - 1
            if (svgLineCapCoversPoint(
                contour[last],
                contour[last - 1],
                point,
                halfWidth,
                cap
            ) && svgDistanceToPoint(point, contour[last]) <= halfWidth) {
                return true
            }
        }
    }
    false
}

/** 端点帽是否覆盖：round 用圆盘；square 用沿线延伸的半宽矩形；butt 不额外覆盖。 */
private func svgLineCapCoversPoint(
    endpoint: SvgPoint,
    neighbor: SvgPoint,
    point: SvgPoint,
    halfWidth: Float64,
    cap: SvgLineCap
): Bool {
    match (cap) {
        case Butt => false
        case Round => svgDistanceToPoint(point, endpoint) <= halfWidth
        case Square =>
            let length = svgDistanceToPoint(endpoint, neighbor)
            if (length <= SVG_HIT_EPSILON) {
                return false
            }
            let ux = (endpoint.x - neighbor.x) / length
            let uy = (endpoint.y - neighbor.y) / length
            let dx = point.x - endpoint.x
            let dy = point.y - endpoint.y
            let along = dx * ux + dy * uy
            let across = abs(dx * uy - dy * ux)
            along >= 0.0 && along <= halfWidth && across <= halfWidth
    }
}

private func svgDistanceToSegment(point: SvgPoint, a: SvgPoint, b: SvgPoint): Float64 {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if (lengthSquared <= SVG_HIT_EPSILON) {
        return svgDistanceToPoint(point, a)
    }
    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
    if (t < 0.0) {
        t = 0.0
    } else if (t > 1.0) {
        t = 1.0
    }
    svgDistanceToPoint(point, SvgPoint(a.x + t * dx, a.y + t * dy))
}

private func svgDistanceToPoint(a: SvgPoint, b: SvgPoint): Float64 {
    let dx = a.x - b.x
    let dy = a.y - b.y
    sqrt(dx * dx + dy * dy)
}

private func svgPointOnSegment(point: SvgPoint, a: SvgPoint, b: SvgPoint): Bool {
    if (svgDistanceToSegment(point, a, b) > SVG_HIT_EPSILON) {
        return false
    }
    let minX = if (a.x < b.x) { a.x } else { b.x }
    let maxX = if (a.x > b.x) { a.x } else { b.x }
    let minY = if (a.y < b.y) { a.y } else { b.y }
    let maxY = if (a.y > b.y) { a.y } else { b.y }
    point.x >= minX - SVG_HIT_EPSILON && point.x <= maxX + SVG_HIT_EPSILON &&
    point.y >= minY - SVG_HIT_EPSILON && point.y <= maxY + SVG_HIT_EPSILON
}
