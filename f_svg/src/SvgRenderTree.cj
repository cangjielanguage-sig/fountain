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

/** 显示列表指令种类。 */
public enum SvgDisplayCommandKind <: Equatable<SvgDisplayCommandKind> & ToString {
    | FillPath
    | StrokePath
    | Image
    | Text
    | GroupBegin
    | GroupEnd

    public operator func ==(that: SvgDisplayCommandKind): Bool {
        match ((this, that)) {
            case (FillPath, FillPath) => true
            case (StrokePath, StrokePath) => true
            case (Image, Image) => true
            case (Text, Text) => true
            case (GroupBegin, GroupBegin) => true
            case (GroupEnd, GroupEnd) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case FillPath => "FillPath"
            case StrokePath => "StrokePath"
            case Image => "Image"
            case Text => "Text"
            case GroupBegin => "GroupBegin"
            case GroupEnd => "GroupEnd"
        }
    }
}

/** 一条扁平渲染指令。 */
public class SvgDisplayCommand {
    public let kind: SvgDisplayCommandKind
    public let tag: String
    public let matrix: SvgMatrix
    public let path: ?SvgPathData
    public let textElement: ?SvgTextElement
    public let style: ?SvgComputedStyle
    public let bounds: ?SvgBounds
    public let opacity: Float64
    public let clipPath: ?SvgElement
    public let mask: ?SvgElement
    public let clipRect: ?SvgBounds

    internal init(
        kind: SvgDisplayCommandKind,
        tag: String,
        matrix: SvgMatrix,
        path!: ?SvgPathData = None,
        textElement!: ?SvgTextElement = None,
        style!: ?SvgComputedStyle = None,
        bounds!: ?SvgBounds = None,
        opacity!: Float64 = 1.0,
        clipPath!: ?SvgElement = None,
        mask!: ?SvgElement = None,
        clipRect!: ?SvgBounds = None
    ) {
        this.kind = kind
        this.tag = tag
        this.matrix = matrix
        this.path = path
        this.textElement = textElement
        this.style = style
        this.bounds = bounds
        this.opacity = opacity
        this.clipPath = clipPath
        this.mask = mask
        this.clipRect = clipRect
    }
}

/** 扁平显示列表。 */
public class SvgDisplayList {
    public let commands: Array<SvgDisplayCommand>
    public let root: SvgElement
    public let width: Int64
    public let height: Int64
    public let logicalWidth: Float64
    public let logicalHeight: Float64

    internal init(
        commands: Array<SvgDisplayCommand>,
        root: SvgElement,
        width: Int64,
        height: Int64,
        logicalWidth: Float64,
        logicalHeight: Float64
    ) {
        this.commands = commands
        this.root = root
        this.width = width
        this.height = height
        this.logicalWidth = logicalWidth
        this.logicalHeight = logicalHeight
    }
}

private class SvgRenderTreeContext {
    let matrix: SvgMatrix
    let width: Float64
    let height: Float64
    let clipRect: ?SvgBounds
    let styles: SvgComputedStyleTree
    let root: SvgElement
    let depth: Int64
    let useStack: Array<String>
    let fonts: ?SvgFontRegistry

    init(
        matrix: SvgMatrix,
        width: Float64,
        height: Float64,
        clipRect: ?SvgBounds,
        styles: SvgComputedStyleTree,
        root: SvgElement,
        depth: Int64,
        useStack: Array<String>,
        fonts: ?SvgFontRegistry
    ) {
        this.matrix = matrix
        this.width = width
        this.height = height
        this.clipRect = clipRect
        this.styles = styles
        this.root = root
        this.depth = depth
        this.useStack = useStack
        this.fonts = fonts
    }
}

/**
 * 渲染树构建器：展开 use / symbol / 嵌套 svg，跳过 display:none 与定义性容器，
 * 输出扁平显示列表。构建过程只读文档。
 */
public class SvgRenderTreeBuilder {
    public let warnings = ArrayList<String>()

    public func build(document: SvgDocument, options!: SvgRenderOptions = SvgRenderOptions()): SvgDisplayList {
        let root = document.root
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(root)
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let viewport = SvgViewport.from(root, 300.0, 150.0)
        let logicalWidth = if (options.width > 0) { Float64(options.width) } else { viewport.width }
        let logicalHeight = if (options.height > 0) { Float64(options.height) } else { viewport.height }
        let ratio = options.devicePixelRatio
        let outputWidth = maxInt64(1, ceilSvgPixel(logicalWidth * ratio))
        let outputHeight = maxInt64(1, ceilSvgPixel(logicalHeight * ratio))
        let matrix = SvgMatrix.scale(ratio, ratio)
            .multiply(viewport.transform(root))
            .multiply(elementTransformMatrix(root))
        let commands = ArrayList<SvgDisplayCommand>()
        match (styles.get(root)) {
            case Some(rootStyle) =>
                if (rootStyle.display() != "none") {
                    let context = SvgRenderTreeContext(
                        matrix,
                        logicalWidth,
                        logicalHeight,
                        None,
                        styles,
                        root,
                        0,
                        Array<String>(),
                        options.fonts
                    )
                    this.walkChildren(root, context, commands)
                }
            case None => ()
        }
        SvgDisplayList(commands.toArray(), root, outputWidth, outputHeight, logicalWidth, logicalHeight)
    }

    public func buildElement(
        element: SvgElement,
        width: Int64,
        height: Int64,
        options!: SvgRenderOptions = SvgRenderOptions()
    ): SvgDisplayList {
        if (width <= 0 || height <= 0) {
            throw invalidValue("render(element) 的宽高必须为正")
        }
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(element)
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let ratio = options.devicePixelRatio
        let outputWidth = maxInt64(1, ceilSvgPixel(Float64(width) * ratio))
        let outputHeight = maxInt64(1, ceilSvgPixel(Float64(height) * ratio))
        let matrix = SvgMatrix.scale(ratio, ratio)
        let commands = ArrayList<SvgDisplayCommand>()
        let context = SvgRenderTreeContext(
            matrix,
            Float64(width),
            Float64(height),
            None,
            styles,
            element,
            0,
            Array<String>(),
            options.fonts
        )
        this.walkElement(element, context, commands)
        SvgDisplayList(commands.toArray(), element, outputWidth, outputHeight, Float64(width), Float64(height))
    }

    private func walkChildren(
        element: SvgElement,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>
    ): Unit {
        for (node in element.children) {
            match (node) {
                case ElementNode(child) => this.walkElement(child, context, commands)
                case _ => ()
            }
        }
    }

    private func walkElement(
        element: SvgElement,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>
    ): Unit {
        let style = match (context.styles.get(element)) {
            case Some(value) => value
            case None => return
        }
        if (style.display() == "none") {
            return
        }
        match (element) {
            case svg: SvgRoot =>
                this.walkNestedSvg(svg, context, commands)
                return
            case use: SvgUse =>
                this.expandUse(use, context, commands)
                return
            case container: SvgContainer =>
                this.walkContainer(container, context, commands, style)
                return
            case image: SvgImage =>
                this.addImage(image, context, commands, style)
                return
            case text: SvgTextElement =>
                if (style.visibility() == "hidden") {
                    return
                }
                let matrix = context.matrix.multiply(elementTransformMatrix(text))
                let bounds = SvgGeometry.bounds(text, style: style, fonts: context.fonts)
                commands.add(
                    SvgDisplayCommand(
                        SvgDisplayCommandKind.Text,
                        text.tag,
                        matrix,
                        textElement: Some(text),
                        style: Some(style),
                        bounds: bounds,
                        opacity: style.opacity(),
                        clipPath: this.resolveUrlRef(style.get("clip-path"), context),
                        mask: this.resolveUrlRef(style.get("mask"), context),
                        clipRect: context.clipRect
                    )
                )
                return
            case shape: SvgShape =>
                this.addShape(shape, context, commands, style)
                return
            case _ => ()
        }
        if (element.tag == "foreignObject" || element.tag == "mathml") {
            this.warnings.add("已跳过不支持的元素「${element.tag}」")
        }
    }

    private func walkContainer(
        container: SvgContainer,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        match (container.kind) {
            case Defs | Symbol | Marker | Pattern | ClipPath | Mask => return
            case _ => ()
        }
        let matrix = context.matrix.multiply(elementTransformMatrix(container))
        let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
        let maskElement = this.resolveUrlRef(style.get("mask"), context)
        let grouped = style.opacity() < 1.0 || clipPath.isSome() || maskElement.isSome() ||
            context.clipRect.isSome()
        if (grouped) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.GroupBegin,
                    container.tag,
                    matrix,
                    opacity: style.opacity(),
                    clipPath: clipPath,
                    mask: maskElement,
                    clipRect: context.clipRect
                )
            )
        }
        let childContext = SvgRenderTreeContext(
            matrix,
            context.width,
            context.height,
            None,
            context.styles,
            context.root,
            context.depth,
            context.useStack,
            context.fonts
        )
        if (container.kind == SvgContainerKind.Switch) {
            for (node in container.children) {
                match (node) {
                    case ElementNode(child) =>
                        match (context.styles.get(child)) {
                            case Some(childStyle) => if (childStyle.display() != "none") {
                                this.walkElement(child, childContext, commands)
                                break
                            }
                            case None => ()
                        }
                    case _ => ()
                }
            }
        } else {
            this.walkChildren(container, childContext, commands)
        }
        if (grouped) {
            commands.add(
                SvgDisplayCommand(SvgDisplayCommandKind.GroupEnd, container.tag, matrix)
            )
        }
    }

    private func walkNestedSvg(
        svg: SvgRoot,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>
    ): Unit {
        if (context.depth > 64) {
            throw SvgException("嵌套 svg 深度超过 64", kind: SvgErrorKind.Limit)
        }
        let viewport = SvgViewport.nestedViewport(svg, context.width, context.height)
        var matrix = SvgViewport.nestedTransform(context.matrix, svg, context.width, context.height)
        matrix = matrix.multiply(elementTransformMatrix(svg))
        let originX = lengthOrZero(svg.x)
        let originY = lengthOrZero(svg.y)
        let p0 = context.matrix.apply(SvgPoint(originX, originY))
        let p1 = context.matrix.apply(SvgPoint(originX + viewport.width, originY + viewport.height))
        let clip = SvgBounds(
            if (p0.x < p1.x) { p0.x } else { p1.x },
            if (p0.y < p1.y) { p0.y } else { p1.y },
            abs(p1.x - p0.x),
            abs(p1.y - p0.y)
        )
        let combinedClip = match (context.clipRect) {
            case Some(existing) => existing.intersect(clip)
            case None => clip
        }
        let childContext = SvgRenderTreeContext(
            matrix,
            viewport.width,
            viewport.height,
            Some(combinedClip),
            context.styles,
            context.root,
            context.depth + 1,
            context.useStack,
            context.fonts
        )
        this.walkChildren(svg, childContext, commands)
    }

    private func expandUse(
        use: SvgUse,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>
    ): Unit {
        let href = readSvgHref(use)
        let targetId = match (href) {
            case Some(value) => stripSvgHash(value)
            case None => ""
        }
        if (targetId.size == 0) {
            this.warnings.add("use 缺少 href")
            return
        }
        if (context.depth >= 64) {
            if (arrayContainsSvgString(context.useStack, targetId)) {
                this.warnings.add("use 循环引用在深度 64 终止")
                return
            }
            throw SvgException("use 引用深度超过 64", kind: SvgErrorKind.Limit)
        }
        let target = match (findSvgElementById(Some(context.root), targetId)) {
            case Some(value) => value
            case None =>
                this.warnings.add("use 引用目标「${targetId}」不存在")
                return
        }
        let x = lengthOrZero(use.x)
        let y = lengthOrZero(use.y)
        var matrix = context.matrix.multiply(SvgMatrix.translate(x, y))
        var clipRect = context.clipRect
        match (target) {
            case container: SvgContainer =>
                if (container.kind == SvgContainerKind.Symbol) {
                    let width = match (use.width) {
                        case Some(value) => value.value
                        case None => symbolDimension(container, "viewBox", 2) ?? 100.0
                    }
                    let height = match (use.height) {
                        case Some(value) => value.value
                        case None => symbolDimension(container, "viewBox", 3) ?? 100.0
                    }
                    let viewBox: ?SvgViewBox = match (container.attr("viewBox")) {
                        case Some(text) => tryParseSvgViewBox(text)
                        case None => None
                    }
                    match (viewBox) {
                        case Some(box) =>
                            let aspect = match (container.attr("preserveAspectRatio")) {
                                case Some(text) => tryParseSvgPreserveAspectRatio(text) ??
                                    SvgPreserveAspectRatio.Default
                                case None => SvgPreserveAspectRatio.Default
                            }
                            matrix = matrix.multiply(aspect.toMatrix(box, width, height))
                            let p0 = matrix.apply(SvgPoint(0.0, 0.0))
                            let p1 = matrix.apply(SvgPoint(width, height))
                            clipRect = Some(
                                SvgBounds(
                                    if (p0.x < p1.x) { p0.x } else { p1.x },
                                    if (p0.y < p1.y) { p0.y } else { p1.y },
                                    abs(p1.x - p0.x),
                                    abs(p1.y - p0.y)
                                )
                            )
                        case None => ()
                    }
                }
            case _ => ()
        }
        matrix = matrix.multiply(elementTransformMatrix(target))
        let nextStack = ArrayList<String>()
        for (id in context.useStack) {
            nextStack.add(id)
        }
        nextStack.add(targetId)
        let childContext = SvgRenderTreeContext(
            matrix,
            context.width,
            context.height,
            clipRect,
            context.styles,
            context.root,
            context.depth + 1,
            nextStack.toArray(),
            context.fonts
        )
        if (target.tag == "symbol") {
            this.walkChildren(target, childContext, commands)
        } else {
            this.walkElement(target, childContext, commands)
        }
    }

    private func addShape(
        shape: SvgShape,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        if (style.visibility() == "hidden") {
            return
        }
        let path = match (elementPathData(shape)) {
            case Some(value) => value
            case None => return
        }
        let matrix = context.matrix.multiply(elementTransformMatrix(shape))
        let bounds = SvgGeometry.bounds(shape, style: style)
        let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
        let maskElement = this.resolveUrlRef(style.get("mask"), context)
        let fill = style.fill()
        if (fill.kind != SvgPaintKind.None) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.FillPath,
                    shape.tag,
                    matrix,
                    path: Some(path),
                    style: Some(style),
                    bounds: bounds,
                    opacity: style.opacity(),
                    clipPath: clipPath,
                    mask: maskElement,
                    clipRect: context.clipRect
                )
            )
        }
        let stroke = style.stroke()
        if (stroke.kind != SvgPaintKind.None) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.StrokePath,
                    shape.tag,
                    matrix,
                    path: Some(path),
                    style: Some(style),
                    bounds: bounds,
                    opacity: style.opacity(),
                    clipPath: clipPath,
                    mask: maskElement,
                    clipRect: context.clipRect
                )
            )
        }
    }

    private func addImage(
        image: SvgImage,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        this.warnings.add("<image> 在 M2 不解码，使用占位矩形")
        let x = lengthOrZero(image.x)
        let y = lengthOrZero(image.y)
        let width = lengthOrZero(image.width)
        let height = lengthOrZero(image.height)
        commands.add(
            SvgDisplayCommand(
                SvgDisplayCommandKind.Image,
                "image",
                context.matrix.multiply(elementTransformMatrix(image)),
                style: Some(style),
                bounds: Some(SvgBounds(x, y, width, height)),
                opacity: style.opacity(),
                clipRect: context.clipRect
            )
        )
    }

    private func resolveUrlRef(value: ?String, context: SvgRenderTreeContext): ?SvgElement {
        match (value) {
            case Some(text) =>
                let trimmed = text.trimAscii()
                if (trimmed.size < 4 || trimmed[0..4] != "url(") {
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
                match (findSvgElementById(Some(context.root), inner)) {
                    case Some(element) => Some(element)
                    case None =>
                        this.warnings.add("引用目标「${inner}」不存在")
                        None
                }
            case None => None
        }
    }
}

private func elementTransformMatrix(element: SvgElement): SvgMatrix {
    match (element.transform) {
        case Some(transform) => transform.toMatrix()
        case None => SvgMatrix.identity
    }
}

internal func findSvgElementById(element: ?SvgElement, id: String): ?SvgElement {
    match (element) {
        case Some(node) =>
            if (node.attr("id") == Some(id)) {
                return Some(node)
            }
            for (child in node.children) {
                match (child) {
                    case ElementNode(next) =>
                        match (findSvgElementById(Some(next), id)) {
                            case Some(found) => return Some(found)
                            case None => ()
                        }
                    case _ => ()
                }
            }
            None
        case None => None
    }
}

private func symbolDimension(container: SvgContainer, name: String, index: Int64): ?Float64 {
    match (container.attr(name)) {
        case Some(text) =>
            match (tryParseSvgViewBox(text)) {
                case Some(box) => if (index == 2) { Some(box.width) } else { Some(box.height) }
                case None => None
            }
        case None => None
    }
}

private func maxInt64(first: Int64, second: Int64): Int64 {
    if (first > second) { first } else { second }
}

/** 像素尺寸向上取整；减去相对 epsilon 抵消浮点乘法误差。 */
private func ceilSvgPixel(value: Float64): Int64 {
    let tolerance = if (value > 1.0) { value * 1e-12 } else { 1e-12 }
    Int64(ceil(value - tolerance))
}

private func arrayContainsSvgString(values: Array<String>, target: String): Bool {
    for (value in values) {
        if (value == target) {
            return true
        }
    }
    false
}
