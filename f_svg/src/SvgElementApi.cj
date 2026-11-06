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
    SvgStyleResolver().computeElement(element, None)
}

/** 元素用户空间包围盒；计算样式与字体上下文由调用方提供。 */
internal func svgBBoxOf(
    element: SvgElement,
    options: SvgBBoxOptions,
    styles: ?SvgComputedStyleTree
): ?SvgBounds {
    match (element.tag) {
        case "defs" | "symbol" | "marker" | "pattern" | "clipPath" | "mask" | "linearGradient" |
            "radialGradient" | "filter" | "style" | "stop" => return Option<SvgBounds>.None
        case _ => ()
    }
    let style = svgStyleFor(element, styles)
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
            return svgUseBBox(use, options, styles)
        case container: SvgContainer =>
            return svgContainerBBox(container, options, styles)
        case root: SvgRoot =>
            return svgContainerBBox(root, options, styles)
        case _ => ()
    }
    let base = if (options.stroke) {
        SvgGeometry.strokeBounds(element, style: style, fonts: options.fonts)
    } else {
        SvgGeometry.bounds(element, style: style, fonts: options.fonts)
    }
    match (base) {
        case Some(box) => Some(applyBBoxClip(element, box, options))
        case None => Option<SvgBounds>.None
    }
}

private func svgContainerBBox(
    container: SvgElement,
    options: SvgBBoxOptions,
    styles: ?SvgComputedStyleTree
): ?SvgBounds {
    var result: ?SvgBounds = None
    for (node in container.children) {
        match (node) {
            case ElementNode(child) =>
                let childBox = match (svgBBoxOf(child, options, styles)) {
                    case Some(value) => value
                    case None => continue
                }
                let transformed = childBox.transform(svgChildTransform(child))
                result = match (result) {
                    case Some(existing) => Some(existing.union(transformed))
                    case None => Some(transformed)
                }
            case _ => ()
        }
    }
    match (result) {
        case Some(box) => Some(applyBBoxClip(container, box, options))
        case None => Option<SvgBounds>.None
    }
}

/** 子元素自身的变换（不含祖先），供容器包围盒并集使用。 */
private func svgChildTransform(element: SvgElement): SvgMatrix {
    match (element.transform) {
        case Some(transform) => transform.toMatrix()
        case None => SvgMatrix.identity
    }
}

private func svgUseBBox(
    use: SvgUse,
    options: SvgBBoxOptions,
    styles: ?SvgComputedStyleTree
): ?SvgBounds {
    let href = readSvgHref(use)
    let id = match (href) {
        case Some(value) => stripSvgHash(value)
        case None => ""
    }
    if (id.size == 0) {
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
    let base = match (svgBBoxOf(target, options, styles)) {
        case Some(value) => value
        case None => return Option<SvgBounds>.None
    }
    let x = match (use.x) {
        case Some(value) => value.value
        case None => 0.0
    }
    let y = match (use.y) {
        case Some(value) => value.value
        case None => 0.0
    }
    let translated = base.transform(SvgMatrix.translate(x, y))
    Some(applyBBoxClip(use, translated, options))
}

/** `clipped` 与祖先视口矩形求交；只处理根与非嵌套 svg 视口。 */
private func applyBBoxClip(element: SvgElement, box: SvgBounds, options: SvgBBoxOptions): SvgBounds {
    if (!options.clipped) {
        return box
    }
    var clip: ?SvgBounds = None
    var current = element.parent
    while (true) {
        match (current) {
            case Some(node) =>
                match (node) {
                    case root: SvgRoot =>
                        let viewport = SvgViewport.from(root, 300.0, 150.0)
                        let rect = SvgBounds(0.0, 0.0, viewport.width, viewport.height)
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

/** 元素到根用户空间的矩阵（未挂载时为单位矩阵）。 */
internal func svgElementCtm(element: SvgElement): SvgMatrix {
    let root = match (svgRootOf(element)) {
        case Some(value) => value
        case None => return SvgMatrix.identity
    }
    let tree = SvgStyleResolver().compute(root)
    SvgGeometry.ctm(element, styles: tree)
}

/** 元素到设备空间的矩阵；`viewport` 为空时按根尺寸与 DPR 1 构造。 */
internal func svgElementScreenCtm(element: SvgElement, viewport: ?SvgViewportTransform): SvgMatrix {
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
    let tree = SvgStyleResolver().compute(root)
    SvgMatrix.scale(transform.devicePixelRatio, transform.devicePixelRatio)
        .multiply(transform.matrix)
        .multiply(SvgGeometry.ctm(element, styles: tree))
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
