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

/** `getBBox` 的选项。 */
public struct SvgBBoxOptions {
    /** 并入描边外扩。 */
    public let stroke: Bool
    /** 与有效视口裁剪矩形求交（不处理 `clip-path` / `mask`）。 */
    public let clipped: Bool
    /** 文本测量使用的字体注册表；`None` 时用默认注册表。 */
    public let fonts: ?SvgFontRegistry

    public init(
        stroke!: Bool = false,
        clipped!: Bool = false,
        fonts!: ?SvgFontRegistry = None
    ) {
        this.stroke = stroke
        this.clipped = clipped
        this.fonts = fonts
    }
}

/** 沿 `parent` 链找到根元素；未挂载返回 `None`。 */
internal func svgRootOf(element: SvgElement): ?SvgElement {
    var current: ?SvgElement = Some(element)
    var root: ?SvgElement = None
    while (true) {
        match (current) {
            case Some(node) =>
                root = Some(node)
                current = node.parent
            case None => break
        }
    }
    match (root) {
        case Some(value) => if (value.parent.isNone()) {
            Some(value)
        } else {
            None
        }
        case None => None
    }
}

/** 元素自身的计算样式；优先使用样式树，未挂载时现场计算。 */
internal func svgStyleFor(element: SvgElement, styles: ?SvgComputedStyleTree): SvgComputedStyle {
    match (styles) {
        case Some(tree) =>
            match (tree.get(element)) {
                case Some(value) => return value
                case None => ()
            }
        case None => ()
    }
    SvgStyleResolver().computeElement(element, Option<SvgComputedStyle>.None)
}

/** `getBBox` 递归所需的只读上下文。 */
internal class SvgBBoxRequest {
    let options: SvgBBoxOptions
    let styles: ?SvgComputedStyleTree
    let viewportWidth: Float64
    let viewportHeight: Float64
    let useStack: Array<String>

    init(
        options: SvgBBoxOptions,
        styles: ?SvgComputedStyleTree,
        viewportWidth!: Float64 = 300.0,
        viewportHeight!: Float64 = 150.0,
        useStack!: Array<String> = Array<String>()
    ) {
        this.options = options
        this.styles = styles
        this.viewportWidth = viewportWidth
        this.viewportHeight = viewportHeight
        this.useStack = useStack
    }

    func withUse(id: String): SvgBBoxRequest {
        let stack = ArrayList<String>()
        for (value in this.useStack) {
            stack.add(value)
        }
        stack.add(id)
        SvgBBoxRequest(
            this.options,
            this.styles,
            viewportWidth: this.viewportWidth,
            viewportHeight: this.viewportHeight,
            useStack: stack.toArray()
        )
    }

    func containsUse(id: String): Bool {
        for (value in this.useStack) {
            if (value == id) {
                return true
            }
        }
        false
    }
}

/** 元素用户空间包围盒；计算样式与字体上下文由调用方提供。 */
internal func svgBBoxOf(element: SvgElement, request: SvgBBoxRequest): ?SvgBounds {
    match (element.tag) {
        case "defs" | "marker" | "pattern" | "clipPath" | "mask" | "linearGradient" |
            "radialGradient" | "filter" | "style" | "stop" => return Option<SvgBounds>.None
        case _ => ()
    }
    let style = svgStyleFor(element, request.styles)
    if (style.display() == "none") {
        return Option<SvgBounds>.None
    }
    match (element) {
        case image: SvgImage =>
            let x = lengthOrZero(svgStyledLength(Some(style), "x", image.x))
            let y = lengthOrZero(svgStyledLength(Some(style), "y", image.y))
            let width = lengthOrZero(svgStyledLength(Some(style), "width", image.width))
            let height = lengthOrZero(svgStyledLength(Some(style), "height", image.height))
            if (width < 0.0 || height < 0.0) {
                return Option<SvgBounds>.None
            }
            return Some(SvgBounds(x, y, width, height))
        case use: SvgUse =>
            return svgUseBBox(use, request)
        case container: SvgContainer =>
            return svgContainerBBox(container, request)
        case root: SvgRoot =>
            return svgContainerBBox(root, request)
        case _ => ()
    }
    if (style.visibility() == "hidden") {
        return Option<SvgBounds>.None
    }
    let base = if (request.options.stroke) {
        SvgGeometry.strokeBounds(element, style: style, fonts: request.options.fonts)
    } else {
        SvgGeometry.bounds(element, style: style, fonts: request.options.fonts)
    }
    match (base) {
        case Some(box) => Some(applyBBoxClip(element, box, request))
        case None => Option<SvgBounds>.None
    }
}

private func svgContainerBBox(
    container: SvgElement,
    request: SvgBBoxRequest
): ?SvgBounds {
    var result: ?SvgBounds = None
    for (node in container.children) {
        match (node) {
            case ElementNode(child) =>
                let childBox = match (svgBBoxOf(child, request)) {
                    case Some(value) => value
                    case None => continue
                }
                let transformed = childBox.transform(svgChildTransform(child, request, childBox))
                result = match (result) {
                    case Some(existing) => Some(existing.union(transformed))
                    case None => Some(transformed)
                }
            case _ => ()
        }
    }
    match (result) {
        case Some(box) => Some(applyBBoxClip(container, box, request))
        case None => Option<SvgBounds>.None
    }
}

/** 子元素自身的变换（不含祖先），供容器包围盒并集使用。 */
private func svgChildTransform(
    element: SvgElement,
    request: SvgBBoxRequest,
    bounds: ?SvgBounds
): SvgMatrix {
    let style = svgStyleFor(element, request.styles)
    effectiveElementTransform(
        element,
        style: Some(style),
        bounds: bounds,
        viewportWidth: request.viewportWidth,
        viewportHeight: request.viewportHeight
    )
}

private func svgUseBBox(use: SvgUse, request: SvgBBoxRequest): ?SvgBounds {
    let href = readSvgHref(use)
    let id = match (href) {
        case Some(value) => stripSvgHash(value)
        case None => ""
    }
    if (id.size == 0 || request.containsUse(id)) {
        return Option<SvgBounds>.None
    }
    let root = match (svgRootOf(use)) {
        case Some(value) => value
        case None => return Option<SvgBounds>.None
    }
    let target = match (findSvgElementById(Some(root), id)) {
        case Some(value) => value
        case None => return Option<SvgBounds>.None
    }
    let nestedRequest = request.withUse(id)
    let base = if (target.tag == "symbol") {
        match (svgContainerBBox(target, nestedRequest)) {
            case Some(value) => value
            case None => return Option<SvgBounds>.None
        }
    } else {
        match (svgBBoxOf(target, nestedRequest)) {
            case Some(value) => value
            case None => return Option<SvgBounds>.None
        }
    }
    let targetTransform = svgChildTransform(target, nestedRequest, Some(base))
    let x = match (use.x) {
        case Some(value) => value.value
        case None => 0.0
    }
    let y = match (use.y) {
        case Some(value) => value.value
        case None => 0.0
    }
    let translated = base.transform(targetTransform)
        .transform(SvgMatrix.translate(x, y))
    Some(applyBBoxClip(use, translated, request))
}

/** `clipped` 与祖先视口矩形求交；嵌套 svg 有 viewBox 时使用 viewBox 尺寸。 */
private func applyBBoxClip(element: SvgElement, box: SvgBounds, request: SvgBBoxRequest): SvgBounds {
    if (!request.options.clipped) {
        return box
    }
    var clip: ?SvgBounds = None
    var current = element.parent
    while (true) {
        match (current) {
            case Some(node) =>
                match (node) {
                    case root: SvgRoot =>
                        let rect = if (node.parent.isNone()) {
                            let viewport = SvgViewport.from(
                                root,
                                request.viewportWidth,
                                request.viewportHeight
                            )
                            SvgBounds(0.0, 0.0, viewport.width, viewport.height)
                        } else {
                            nestedSvgClipRect(root, request)
                        }
                        clip = match (clip) {
                            case Some(existing) => Some(existing.intersect(rect))
                            case None => Some(rect)
                        }
                    case _ => ()
                }
                current = node.parent
            case None => break
        }
    }
    match (clip) {
        case Some(value) => box.intersect(value)
        case None => box
    }
}

private func nestedSvgClipRect(root: SvgRoot, request: SvgBBoxRequest): SvgBounds {
    match (root.attr("viewBox")) {
        case Some(text) =>
            match (tryParseSvgViewBox(text)) {
                case Some(viewBox) => SvgBounds(viewBox.minX, viewBox.minY, viewBox.width, viewBox.height)
                case None => SvgBounds(0.0, 0.0, request.viewportWidth, request.viewportHeight)
            }
        case None =>
            let viewport = SvgViewport.nestedViewport(root, request.viewportWidth, request.viewportHeight)
            SvgBounds(0.0, 0.0, viewport.width, viewport.height)
    }
}

/** 元素到根用户空间的矩阵（未挂载时为单位矩阵）。 */
internal func svgElementCtm(
    element: SvgElement,
    mediaWidth!: ?Float64 = None,
    mediaHeight!: ?Float64 = None
): SvgMatrix {
    let root = match (svgRootOf(element)) {
        case Some(value) => value
        case None => return SvgMatrix.identity
    }
    let width = mediaWidth ?? 300.0
    let height = mediaHeight ?? 150.0
    let tree = SvgStyleResolver().compute(root, mediaWidth: width, mediaHeight: height)
    SvgGeometry.ctm(
        element,
        styles: tree,
        viewportWidth: width,
        viewportHeight: height
    )
}

/** 元素到设备空间的矩阵；`viewport` 为空时按根尺寸与 DPR 1 构造。 */
internal func svgElementScreenCtm(
    element: SvgElement,
    viewport: ?SvgViewportTransform,
    mediaWidth!: ?Float64 = None,
    mediaHeight!: ?Float64 = None
): SvgMatrix {
    let root = match (svgRootOf(element)) {
        case Some(value) => value
        case None => return SvgMatrix.identity
    }
    let transform = match (viewport) {
        case Some(value) => value
        case None =>
            match (root) {
                case svgRoot: SvgRoot => SvgViewportTransform.from(svgRoot)
                case _ => SvgViewportTransform(300.0, 150.0, SvgMatrix.identity, 1.0)
            }
    }
    let width = mediaWidth ?? transform.width
    let height = mediaHeight ?? transform.height
    let tree = SvgStyleResolver().compute(root, mediaWidth: width, mediaHeight: height)
    SvgMatrix.scale(transform.devicePixelRatio, transform.devicePixelRatio)
        .multiply(transform.matrix)
        .multiply(SvgGeometry.ctm(
            element,
            styles: tree,
            viewportWidth: width,
            viewportHeight: height
        ))
}

/** 后代元素收集（文档顺序，不含自身）。 */
internal func svgDescendants(element: SvgElement): ArrayList<SvgElement> {
    let result = ArrayList<SvgElement>()
    collectSvgDescendants(element, result)
    result
}

private func collectSvgDescendants(element: SvgElement, out: ArrayList<SvgElement>): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                out.add(child)
                collectSvgDescendants(child, out)
            case _ => ()
        }
    }
}

/** 按空白分隔的 class 逐词匹配。 */
internal func svgElementsByClassName(element: SvgElement, name: String): ArrayList<SvgElement> {
    let result = ArrayList<SvgElement>()
    let target = name.trimAscii()
    if (target.size == 0) {
        return result
    }
    for (child in svgDescendants(element)) {
        match (child.attr("class")) {
            case Some(value) => if (cssClassListContains(value, target)) {
                result.add(child)
            }
            case None => ()
        }
    }
    result
}

/** 复用 M5 选择器引擎；非法选择器抛 `InvalidValue`。 */
internal func svgQuerySelectorAll(element: SvgElement, selector: String): ArrayList<SvgElement> {
    let parsed = CssSelector.parse(selector)
    let result = ArrayList<SvgElement>()
    for (child in svgDescendants(element)) {
        if (parsed.matches(child)) {
            result.add(child)
        }
    }
    result
}
