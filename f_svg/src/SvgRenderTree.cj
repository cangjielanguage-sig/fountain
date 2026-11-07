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
    /** 绘制用包围盒（文本不含装饰线，`objectBoundingBox` 渐变以此为准）。 */
    public let bounds: ?SvgBounds
    /** 裁剪 / 滤镜用包围盒；文本含装饰线，其余与 `bounds` 相同。 */
    public let clipBounds: ?SvgBounds
    public let opacity: Float64
    public let clipPath: ?SvgElement
    public let mask: ?SvgElement
    public let clipRect: ?SvgBounds
    /** `<image>` 的资源定位符；非 image 指令为 `None`。 */
    public let href: ?String
    /** `<image>` 的 preserveAspectRatio；缺省由绘制端按 `xMidYMid meet` 处理。 */
    public let aspect: ?SvgPreserveAspectRatio
    /** 元素引用的 `filter` 元素。 */
    public let filter: ?SvgElement
    /** `clip` 属性矩形；在滤镜之后、`clip-path` 之前应用。 */
    public let clip: ?SvgClipRect
    /** 描边是否按设备空间计算（`vector-effect: non-scaling-stroke`）。 */
    public let nonScalingStroke: Bool
    /** 旋转视口 / marker 的设备空间四边形裁剪（按顺序相乘）。 */
    public let clipQuads: Array<Array<SvgPoint>>
    /** 该元素 / 组的混合模式；缺省 `normal`。 */
    public let blendMode: SvgMixBlendMode
    /** 是否建立隔离组（`isolation: isolate`）。 */
    public let isolated: Bool
    /** 构建期已解析的画笔（`context-fill` / `context-stroke`）；`None` 时按样式解析。 */
    public let paintOverride: ?SvgPaint
    /** `foreignObject` 注入的位图；非注入 image 指令为 `None`。 */
    public let bitmap: ?SvgBitmap
    /** 文本轮廓扁平化容差倍率；`None` 时沿用 `shape-rendering`。 */
    internal let textTolerance: ?Float64

    internal init(
        kind: SvgDisplayCommandKind,
        tag: String,
        matrix: SvgMatrix,
        path!: ?SvgPathData = None,
        textElement!: ?SvgTextElement = None,
        style!: ?SvgComputedStyle = None,
        bounds!: ?SvgBounds = None,
        clipBounds!: ?SvgBounds = None,
        opacity!: Float64 = 1.0,
        clipPath!: ?SvgElement = None,
        mask!: ?SvgElement = None,
        clipRect!: ?SvgBounds = None,
        href!: ?String = None,
        aspect!: ?SvgPreserveAspectRatio = None,
        filter!: ?SvgElement = None,
        clip!: ?SvgClipRect = None,
        nonScalingStroke!: Bool = false,
        clipQuads!: Array<Array<SvgPoint>> = Array<Array<SvgPoint>>(),
        blendMode!: SvgMixBlendMode = SvgMixBlendMode.Normal,
        isolated!: Bool = false,
        paintOverride!: ?SvgPaint = None,
        bitmap!: ?SvgBitmap = None,
        textTolerance!: ?Float64 = None
    ) {
        this.kind = kind
        this.tag = tag
        this.matrix = matrix
        this.path = path
        this.textElement = textElement
        this.style = style
        this.bounds = bounds
        this.clipBounds = match (clipBounds) {
            case Some(value) => Some(value)
            case None => bounds
        }
        this.opacity = opacity
        this.clipPath = clipPath
        this.mask = mask
        this.clipRect = clipRect
        this.href = href
        this.aspect = aspect
        this.filter = filter
        this.clip = clip
        this.nonScalingStroke = nonScalingStroke
        this.clipQuads = clipQuads
        this.blendMode = blendMode
        this.isolated = isolated
        this.paintOverride = paintOverride
        this.bitmap = bitmap
        this.textTolerance = textTolerance
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
    /** 构建该列表时使用的计算样式树；文本渲染据此读取 tspan / 祖先样式。 */
    internal let styles: ?SvgComputedStyleTree
    /** 构建与光栅化共享的文本布局缓存；不跨渲染。 */
    internal let textLayouts: ?SvgTextLayoutCache
    /** 本次渲染使用的字体注册表（含 `@font-face` 别名）；`None` 表示按选项回退。 */
    internal let fonts: ?SvgFontRegistry

    internal init(
        commands: Array<SvgDisplayCommand>,
        root: SvgElement,
        width: Int64,
        height: Int64,
        logicalWidth: Float64,
        logicalHeight: Float64,
        styles!: ?SvgComputedStyleTree = None,
        textLayouts!: ?SvgTextLayoutCache = None,
        fonts!: ?SvgFontRegistry = None
    ) {
        this.commands = commands
        this.root = root
        this.width = width
        this.height = height
        this.logicalWidth = logicalWidth
        this.logicalHeight = logicalHeight
        this.styles = styles
        this.textLayouts = textLayouts
        this.fonts = fonts
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
    let clipQuads: Array<Array<SvgPoint>>
    /** 最近的 `use` 实例帧：被引用元素的计算 fill / stroke。 */
    let contextFill: ?SvgPaint
    let contextStroke: ?SvgPaint
    /** 外部文档嵌套深度；主文档为 0。 */
    let externalDepth: Int64
    /** 当前 use 链深度；只在 `expandUse` 内递增，与普通容器嵌套无关。 */
    let useDepth: Int64

    init(
        matrix: SvgMatrix,
        width: Float64,
        height: Float64,
        clipRect: ?SvgBounds,
        styles: SvgComputedStyleTree,
        root: SvgElement,
        depth: Int64,
        useStack: Array<String>,
        fonts: ?SvgFontRegistry,
        clipQuads!: Array<Array<SvgPoint>> = Array<Array<SvgPoint>>(),
        contextFill!: ?SvgPaint = None,
        contextStroke!: ?SvgPaint = None,
        externalDepth!: Int64 = 0,
        useDepth!: Int64 = 0
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
        this.clipQuads = clipQuads
        this.contextFill = contextFill
        this.contextStroke = contextStroke
        this.externalDepth = externalDepth
        this.useDepth = useDepth
    }
}

/**
 * 渲染树构建器：展开 use / symbol / 嵌套 svg，跳过 display:none 与定义性容器，
 * 输出扁平显示列表。构建过程只读文档。
 */
public class SvgRenderTreeBuilder {
    public let warnings = ArrayList<String>()
    internal var guard: ?SvgRenderGuard = None
    internal var languages: Array<String> = ["en"]
    /** 单次渲染的文本布局缓存；随显示列表交给光栅化阶段。 */
    private let textLayouts = SvgTextLayoutCache()
    /** 本次构建的渲染选项；供 foreignObject / 外部文档读取。 */
    private var renderOptions: SvgRenderOptions = SvgRenderOptions()
    /** 单次构建的外部文档缓存；按 href 去重。 */
    private let externalDocuments = HashMap<String, SvgDocument>()
    /** 主文档解析选项；用于复制安全策略。 */
    private var mainParseOptions: SvgParseOptions = SvgParseOptions()

    internal func attachGuard(value: SvgRenderGuard): Unit {
        this.guard = Some(value)
    }

    /** 公开构建入口没有外部会话时自建守卫；后续嵌套构建复用同一实例。 */
    private func ensureGuard(): SvgRenderGuard {
        match (this.guard) {
            case Some(value) => value
            case None =>
                let created = SvgRenderGuard()
                this.guard = Some(created)
                created
        }
    }

    public func build(document: SvgDocument, options!: SvgRenderOptions = SvgRenderOptions()): SvgDisplayList {
        this.ensureGuard()
        this.languages = options.languages
        this.renderOptions = options
        this.mainParseOptions = document.parseOptions
        let root = document.root
        var viewport = SvgViewport.from(root, 300.0, 150.0)
        let resolver = SvgStyleResolver()
        let interaction = SvgInteractionState(
            hoveredIds: options.hoveredIds,
            focusedIds: options.focusedIds,
            root: Some(root)
        )
        var styles = resolver.compute(
            root,
            interaction: interaction,
            mediaWidth: viewport.width,
            mediaHeight: viewport.height
        )
        let widthAuto = root.attr("width")?.trimAscii().toAsciiLower() == "auto"
        let heightAuto = root.attr("height")?.trimAscii().toAsciiLower() == "auto"
        if ((widthAuto || heightAuto) && options.width <= 0 && options.height <= 0) {
            let size = SvgAutoSize.rootSize(
                root,
                styles,
                300.0,
                150.0,
                warnings: Some(this.warnings)
            )
            viewport = SvgViewport(size.width, size.height)
            styles = resolver.compute(
                root,
                interaction: interaction,
                mediaWidth: size.width,
                mediaHeight: size.height
            )
        }
        let logicalWidth = if (options.width > 0) { Float64(options.width) } else { viewport.width }
        let logicalHeight = if (options.height > 0) { Float64(options.height) } else { viewport.height }
        styles = resolver.compute(
            root,
            interaction: interaction,
            mediaWidth: logicalWidth,
            mediaHeight: logicalHeight
        )
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let ratio = options.devicePixelRatio
        let outputWidth = maxInt64(1, ceilSvgPixel(logicalWidth * ratio))
        let outputHeight = maxInt64(1, ceilSvgPixel(logicalHeight * ratio))
        let rootBounds = SvgBounds(0.0, 0.0, logicalWidth, logicalHeight)
        var rootMatrix = viewport.transform(root)
        match (options.initialView) {
            case Some(value) =>
                let id = if (value.trimAscii().startsWith("#")) {
                    value.trimAscii()[1..]
                } else {
                    value.trimAscii()
                }
                match (document.view(id)) {
                    case Some(view) =>
                        match (view.viewBox) {
                            case Some(_) =>
                                rootMatrix = SvgViewport.forView(view, logicalWidth, logicalHeight)
                            case None =>
                                this.warnings.add(
                                    "initialView「${value}」命中的 view 缺少 viewBox，已回退根视口"
                                )
                        }
                    case None =>
                        this.warnings.add("initialView「${value}」未命中 view，已回退根视口")
                }
            case None => ()
        }
        let stateMatrix = match (options.viewState) {
            case Some(value) => value.toMatrix()
            case None => SvgMatrix.identity
        }
        let matrix = SvgMatrix.scale(ratio, ratio)
            .multiply(stateMatrix)
            .multiply(rootMatrix)
            .multiply(
                elementTransformMatrix(
                    root,
                    style: styles.get(root),
                    bounds: Some(rootBounds),
                    viewportWidth: logicalWidth,
                    viewportHeight: logicalHeight
                )
            )
        let commands = ArrayList<SvgDisplayCommand>()
        let derivedFonts = deriveRenderFonts(options.fonts, resolver.fontFaces, this.warnings)
        match (styles.get(root)) {
            case Some(rootStyle) =>
                if (rootStyle.display() != "none") {
                    let context = SvgRenderTreeContext(
                        matrix,
                        logicalWidth,
                        logicalHeight,
                        Option<SvgBounds>.None,
                        styles,
                        root,
                        0,
                        Array<String>(),
                        derivedFonts,
                        clipQuads: Array<Array<SvgPoint>>()
                    )
                    this.walkChildren(root, context, commands)
                }
            case None => ()
        }
        SvgDisplayList(
            commands.toArray(),
            root,
            outputWidth,
            outputHeight,
            logicalWidth,
            logicalHeight,
            styles: Some(styles),
            textLayouts: this.textLayouts,
            fonts: derivedFonts
        )
    }

    /** 以给定初始矩阵渲染容器子内容（pattern tile 等内部复用）。 */
    internal func buildContent(
        container: SvgElement,
        width: Int64,
        height: Int64,
        matrix: SvgMatrix,
        fonts: ?SvgFontRegistry,
        root!: ?SvgElement = None,
        clipRect!: ?SvgBounds = None,
        clipQuads!: Array<Array<SvgPoint>> = Array<Array<SvgPoint>>()
    ): SvgDisplayList {
        this.ensureGuard()
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(container, mediaWidth: Float64(width), mediaHeight: Float64(height))
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let derivedFonts = deriveRenderFonts(fonts, resolver.fontFaces, this.warnings)
        let commands = ArrayList<SvgDisplayCommand>()
        let context = SvgRenderTreeContext(
            matrix,
            Float64(width),
            Float64(height),
            clipRect,
            styles,
            root ?? container,
            0,
            Array<String>(),
            derivedFonts,
            clipQuads: clipQuads
        )
        this.walkChildren(container, context, commands)
        SvgDisplayList(
            commands.toArray(),
            root ?? container,
            width,
            height,
            Float64(width),
            Float64(height),
            styles: Some(styles),
            textLayouts: this.textLayouts,
            fonts: derivedFonts
        )
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
        this.ensureGuard()
        this.languages = options.languages
        this.renderOptions = options
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(
            element,
            interaction: SvgInteractionState(
                hoveredIds: options.hoveredIds,
                focusedIds: options.focusedIds,
                root: Some(element)
            ),
            mediaWidth: Float64(width),
            mediaHeight: Float64(height)
        )
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        let derivedFonts = deriveRenderFonts(options.fonts, resolver.fontFaces, this.warnings)
        let ratio = options.devicePixelRatio
        let outputWidth = maxInt64(1, ceilSvgPixel(Float64(width) * ratio))
        let outputHeight = maxInt64(1, ceilSvgPixel(Float64(height) * ratio))
        let matrix = SvgMatrix.scale(ratio, ratio)
        let commands = ArrayList<SvgDisplayCommand>()
        let context = SvgRenderTreeContext(
            matrix,
            Float64(width),
            Float64(height),
            Option<SvgBounds>.None,
            styles,
            element,
            0,
            Array<String>(),
            derivedFonts,
            clipQuads: Array<Array<SvgPoint>>()
        )
        this.walkElement(element, context, commands)
        SvgDisplayList(
            commands.toArray(),
            element,
            outputWidth,
            outputHeight,
            Float64(width),
            Float64(height),
            styles: Some(styles),
            textLayouts: this.textLayouts,
            fonts: derivedFonts
        )
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
                if (container.kind == SvgContainerKind.ForeignObject) {
                    this.addForeignObject(container, context, commands, style)
                    return
                }
                this.walkContainer(container, context, commands, style)
                return
            case image: SvgImage =>
                this.addImage(image, context, commands, style)
                return
            case text: SvgTextElement =>
                if (style.visibility() == "hidden") {
                    return
                }
                let bounds = SvgGeometry.renderBounds(
                    text,
                    style: style,
                    fonts: context.fonts,
                    root: Some(context.root),
                    styles: Some(context.styles),
                    layoutCache: this.textLayouts
                )
                let matrix = context.matrix.multiply(
                    elementTransformMatrix(
                        text,
                        style: style,
                        bounds: bounds,
                        viewportWidth: context.width,
                        viewportHeight: context.height
                    )
                )
                let clipBounds = SvgGeometry.renderClipBounds(
                    text,
                    style: style,
                    fonts: context.fonts,
                    root: Some(context.root),
                    styles: Some(context.styles),
                    layoutCache: this.textLayouts
                )
                let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
                let maskElement = this.resolveUrlRef(style.get("mask"), context)
                let filterElement = this.resolveUrlRef(style.get("filter"), context)
                let clip = style.clipRect()
                let filtered = filterElement.isSome()
                let elementBlend = svgMixBlendModeOf(style)
                let isolated = style.get("isolation") == Some("isolate")
                if (filtered) {
                    this.appendFilteredGroupBegin(
                        commands,
                        text.tag,
                        matrix,
                        style.opacity(),
                        clipPath,
                        maskElement,
                        context.clipRect,
                        filterElement,
                        clipBounds,
                        clip,
                        context.clipQuads,
                        blendMode: elementBlend
                    )
                }
                let elementGroup = !filtered && (elementBlend != SvgMixBlendMode.Normal || isolated)
                if (elementGroup) {
                    commands.add(
                        SvgDisplayCommand(
                            SvgDisplayCommandKind.GroupBegin,
                            text.tag,
                            matrix,
                            opacity: style.opacity(),
                            bounds: clipBounds,
                            blendMode: elementBlend,
                            isolated: isolated
                        )
                    )
                }
                let grouped = filtered || elementGroup
                commands.add(
                    SvgDisplayCommand(
                        SvgDisplayCommandKind.Text,
                        text.tag,
                        matrix,
                        textElement: Some(text),
                        style: Some(style),
                        bounds: bounds,
                        clipBounds: clipBounds,
                        opacity: if (grouped) { 1.0 } else { style.opacity() },
                        clipPath: if (filtered) { Option<SvgElement>.None } else { clipPath },
                        mask: if (filtered) { Option<SvgElement>.None } else { maskElement },
                        clipRect: if (filtered) { Option<SvgBounds>.None } else { context.clipRect },
                        filter: Option<SvgElement>.None,
                        clip: if (filtered) { Option<SvgClipRect>.None } else { clip },
                        clipQuads: context.clipQuads
                    )
                )
                if (grouped) {
                    commands.add(SvgDisplayCommand(SvgDisplayCommandKind.GroupEnd, text.tag, matrix))
                }
                return
            case shape: SvgShape =>
                this.addShape(shape, context, commands, style)
                return
            case _ => ()
        }
        if (element.tag == "discard") {
            if (element.attr("begin").isNone()) {
                this.warnings.add("discard 元素缺少 begin，已忽略")
            }
            return
        }
        if (element.tag == "foreignObject" || element.tag == "mathml") {
            this.warnings.add("已跳过不支持的元素「${element.tag}」")
        }
    }

    /** `foreignObject`：构建期调用注入渲染器，返回位图复用 Image 指令。 */    private func addForeignObject(
        element: SvgElement,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        let x = svgStyledLengthOrZero(style, "x")
        let y = svgStyledLengthOrZero(style, "y")
        let width = svgStyledLengthOrZero(style, "width")
        let height = svgStyledLengthOrZero(style, "height")
        if (width <= 0.0 || height <= 0.0) {
            this.warnings.add("foreignObject 缺少有效宽高，已跳过")
            return
        }
        if (width > Float64(this.renderOptions.maxPixels) / height) {
            throw SvgException(
                "foreignObject 像素数超过 maxPixels 上限 ${this.renderOptions.maxPixels}",
                kind: SvgErrorKind.Limit
            )
        }
        let renderer = match (this.renderOptions.foreignObjectRenderer) {
            case Some(value) => value
            case None =>
                this.warnings.add("foreignObject 未提供注入渲染器，已按透明占位处理")
                return
        }
        let bitmap = match (renderer.render(element, width, height, this.renderOptions)) {
            case Some(value) => value
            case None =>
                this.warnings.add("foreignObject 渲染器返回 None，已按透明占位处理")
                return
        }
        if (bitmap.width > this.renderOptions.maxPixels / bitmap.height) {
            throw SvgException(
                "foreignObject 位图像素数超过 maxPixels 上限 ${this.renderOptions.maxPixels}",
                kind: SvgErrorKind.Limit
            )
        }
        let box = SvgBounds(x, y, width, height)
        let matrix = context.matrix.multiply(
            elementTransformMatrix(
                element,
                style: style,
                bounds: box,
                viewportWidth: context.width,
                viewportHeight: context.height
            )
        )
        commands.add(
            SvgDisplayCommand(
                SvgDisplayCommandKind.Image,
                element.tag,
                matrix,
                style: Some(style),
                bounds: Some(box),
                opacity: style.opacity(),
                clipRect: context.clipRect,
                clipQuads: context.clipQuads,
                bitmap: Some(bitmap)
            )
        )
    }

    private func walkContainer(        container: SvgContainer,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        match (container.kind) {
            case Defs | Symbol | Marker | Pattern | ClipPath | Mask => return
            case _ => ()
        }
        let containerBounds = if (style.transformBox() == SvgTransformBox.FillBox) {
            svgBBoxOf(
                container,
                SvgBBoxRequest(
                    SvgBBoxOptions(),
                    context.styles,
                    viewportWidth: context.width,
                    viewportHeight: context.height
                )
            )
        } else {
            Option<SvgBounds>.None
        }
        let matrix = context.matrix.multiply(
            elementTransformMatrix(
                container,
                style: style,
                bounds: containerBounds,
                viewportWidth: context.width,
                viewportHeight: context.height
            )
        )
        let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
        let maskElement = this.resolveUrlRef(style.get("mask"), context)
        let filterElement = this.resolveUrlRef(style.get("filter"), context)
        let clip = style.clipRect()
        let blendMode = svgMixBlendModeOf(style)
        let isolated = style.get("isolation") == Some("isolate")
        let grouped = style.opacity() < 1.0 || clipPath.isSome() || maskElement.isSome() ||
            context.clipRect.isSome() || filterElement.isSome() || clip.isSome() ||
            blendMode != SvgMixBlendMode.Normal || isolated
        let childContext = SvgRenderTreeContext(
            matrix,
            context.width,
            context.height,
            Option<SvgBounds>.None,
            context.styles,
            context.root,
            context.depth,
            context.useStack,
            context.fonts,
            clipQuads: context.clipQuads,
            contextFill: context.contextFill,
            contextStroke: context.contextStroke,
            useDepth: context.useDepth
        )
        let childCommands = ArrayList<SvgDisplayCommand>()
        if (container.kind == SvgContainerKind.Switch) {
            match (SvgSwitch.select(container, context.styles, this.languages)) {
                case Some(child) => this.walkElement(child, childContext, childCommands)
                case None => ()
            }
        } else {
            this.walkChildren(container, childContext, childCommands)
        }
        let groupBounds: ?SvgBounds = if (filterElement.isSome()) {
            unionCommandBounds(childCommands, matrix)
        } else {
            None
        }
        if (grouped) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.GroupBegin,
                    container.tag,
                    matrix,
                    opacity: style.opacity(),
                    clipPath: clipPath,
                    mask: maskElement,
                    clipRect: context.clipRect,
                    bounds: groupBounds,
                    filter: filterElement,
                    clip: clip,
                    clipQuads: context.clipQuads,
                    blendMode: blendMode,
                    isolated: isolated
                )
            )
        }
        for (command in childCommands) {
            commands.add(command)
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
        let svgStyle = context.styles.get(svg)
        let svgBounds = SvgBounds(0.0, 0.0, viewport.width, viewport.height)
        let svgTransform = elementTransformMatrix(
            svg,
            style: svgStyle,
            bounds: Some(svgBounds),
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
        var matrix = SvgViewport.nestedTransform(context.matrix, svg, context.width, context.height)
        matrix = matrix.multiply(svgTransform)
        let originX = lengthOrZero(svg.x)
        let originY = lengthOrZero(svg.y)
        let clipMatrix = context.matrix.multiply(svgTransform)
        let clip = transformedRectBounds(
            clipMatrix,
            originX,
            originY,
            viewport.width,
            viewport.height
        )
        let combinedClip = match (context.clipRect) {
            case Some(existing) => existing.intersect(clip)
            case None => clip
        }
        let overflowVisible = match (context.styles.get(svg)) {
            case Some(style) => !style.overflowMode().clips()
            case None => false
        }
        let childClip = if (overflowVisible) { context.clipRect } else { Some(combinedClip) }
        var childQuads = context.clipQuads
        if (!overflowVisible && !isAxisAlignedMatrix(clipMatrix)) {
            childQuads = appendSvgQuad(
                childQuads,
                transformedRectQuad(clipMatrix, originX, originY, viewport.width, viewport.height)
            )
        }
        let childContext = SvgRenderTreeContext(
            matrix,
            viewport.width,
            viewport.height,
            childClip,
            context.styles,
            context.root,
            context.depth + 1,
            context.useStack,
            context.fonts,
            clipQuads: childQuads,
            contextFill: context.contextFill,
            contextStroke: context.contextStroke,
            useDepth: context.useDepth
        )
        this.walkChildren(svg, childContext, commands)
    }

    /** 解析 `use` 的外部 href；缓存按 href 去重，深度与字节上限前置。 */
    private func resolveExternalUse(href: String, context: SvgRenderTreeContext): ?SvgExternalResolution {
        if (!svgExternalDepthAllows(context.externalDepth)) {
            throw SvgException(
                "外部文档引用深度超过 ${SVG_EXTERNAL_MAX_DEPTH}",
                kind: SvgErrorKind.Limit
            )
        }
        let marker = "ext:" + href
        if (arrayContainsSvgString(context.useStack, marker)) {
            this.warnings.add("外部文档循环引用「${href}」已停止")
            return Option<SvgExternalResolution>.None
        }
        let provider = match (this.renderOptions.externalDocuments) {
            case Some(value) => value
            case None =>
                this.warnings.add("未提供外部文档 provider，已跳过「${href}」")
                return Option<SvgExternalResolution>.None
        }
        let document = match (this.externalDocuments.get(href)) {
            case Some(value) => value
            case None =>
                let bytes = match (provider.resolveHref(href)) {
                    case Some(value) => value
                    case None =>
                        this.warnings.add("外部文档「${href}」不可用")
                        return Option<SvgExternalResolution>.None
                }
                if (Int64(bytes.size) > SVG_EXTERNAL_MAX_BYTES) {
                    throw SvgException(
                        "外部文档「${href}」超过 ${SVG_EXTERNAL_MAX_BYTES} 字节上限",
                        kind: SvgErrorKind.Limit
                    )
                }
                let parsed = SvgParser.parse(
                    bytes,
                    options: svgExternalParseOptions(this.mainParseOptions)
                )
                this.externalDocuments[href] = parsed
                for (warning in parsed.warnings) {
                    if (warning.contains("外部引用")) {
                        this.warnings.add("外部文档「${href}」不递归加载：${warning}")
                    }
                }
                parsed
        }
        let fragment = svgHrefFragment(href)
        let target = if (fragment.size == 0) {
            document.root
        } else {
            match (document.elementById(fragment)) {
                case Some(value) => value
                case None =>
                    this.warnings.add("外部文档「${href}」中不存在片段「${fragment}」")
                    return Option<SvgExternalResolution>.None
            }
        }
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(
            document.root,
            mediaWidth: context.width,
            mediaHeight: context.height
        )
        for (warning in resolver.warnings) {
            this.warnings.add(warning)
        }
        SvgExternalResolution(target, styles, document.root, context.externalDepth + 1)
    }

    private func expandUse(
        use: SvgUse,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>
    ): Unit {
        let href = readSvgHref(use)
        let hrefText = match (href) {
            case Some(value) => value.trimAscii()
            case None => ""
        }
        if (hrefText.size == 0) {
            this.warnings.add("use 缺少 href")
            return
        }
        let external = !hrefText.startsWith("#")
        let targetId = if (external) { "" } else { stripSvgHash(hrefText) }
        if (!external && targetId.size == 0) {
            this.warnings.add("use 缺少 href")
            return
        }
        let stackKey = if (external) { "ext:" + hrefText } else { targetId }
        // 循环优先于深度：命中 useStack 即 warning 停止，正常文档不会累积到上限。
        if (arrayContainsSvgString(context.useStack, stackKey)) {
            this.warnings.add("use 循环引用「${stackKey}」已停止")
            return
        }
        if (context.useDepth >= SVG_USE_MAX_DEPTH) {
            throw SvgException("use 引用深度超过 ${SVG_USE_MAX_DEPTH}", kind: SvgErrorKind.Limit)
        }
        var workingStyles = context.styles
        var workingRoot = context.root
        var workingDepth = context.externalDepth
        var resolvedStackKey = stackKey
        var target: SvgElement
        if (external) {
            match (this.resolveExternalUse(hrefText, context)) {
                case Some(value) =>
                    target = value.element
                    workingStyles = value.styles
                    workingRoot = value.root
                    workingDepth = value.depth
                case None => return
            }
        } else {
            target = match (findSvgElementById(Some(context.root), targetId)) {
                case Some(value) => value
                case None =>
                    this.warnings.add("use 引用目标「${targetId}」不存在")
                    return
            }
        }
        let x = lengthOrZero(use.x)
        let y = lengthOrZero(use.y)
        var matrix = context.matrix.multiply(SvgMatrix.translate(x, y))
        var clipRect = context.clipRect
        var childQuads = context.clipQuads
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
                        case None => ()
                    }
                    let overflowVisible = match (workingStyles.get(container)) {
                        case Some(style) => !style.overflowMode().clips()
                        case None => false
                    }
                    if (!overflowVisible) {
                        let symbolClip = transformedRectBounds(matrix, 0.0, 0.0, width, height)
                        clipRect = Some(match (context.clipRect) {
                            case Some(existing) => existing.intersect(symbolClip)
                            case None => symbolClip
                        })
                        if (!isAxisAlignedMatrix(matrix)) {
                            childQuads = appendSvgQuad(
                                childQuads,
                                transformedRectQuad(matrix, 0.0, 0.0, width, height)
                            )
                        }
                    }
                }
            case _ => ()
        }
        let targetStyle = workingStyles.get(target)
        let targetBounds = match (svgBBoxOf(target, SvgBBoxRequest(
            SvgBBoxOptions(),
            workingStyles,
            viewportWidth: context.width,
            viewportHeight: context.height,
            useStack: [stackKey]
        ))) {
            case Some(value) => Some(value)
            case None => Option<SvgBounds>.None
        }
        matrix = matrix.multiply(
            elementTransformMatrix(
                target,
                style: targetStyle,
                bounds: targetBounds,
                viewportWidth: context.width,
                viewportHeight: context.height
            )
        )
        let nextStack = ArrayList<String>()
        for (id in context.useStack) {
            nextStack.add(id)
        }
        nextStack.add(resolvedStackKey)
        let childContext = SvgRenderTreeContext(
            matrix,
            context.width,
            context.height,
            clipRect,
            workingStyles,
            workingRoot,
            context.depth,
            nextStack.toArray(),
            context.fonts,
            clipQuads: childQuads,
            contextFill: useContextFrame(workingStyles, target, true),
            contextStroke: useContextFrame(workingStyles, target, false),
            externalDepth: workingDepth,
            useDepth: context.useDepth + 1
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
        let path = match (elementPathData(shape, style: style)) {
            case Some(value) => value
            case None => return
        }
        let bounds = SvgGeometry.bounds(shape, style: style)
        let localMatrix = elementTransformMatrix(
            shape,
            style: style,
            bounds: bounds,
            viewportWidth: context.width,
            viewportHeight: context.height
        )
        let matrix = svgApplyM6VectorEffects(context.matrix.multiply(localMatrix), style, localMatrix)
        let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
        let maskElement = this.resolveUrlRef(style.get("mask"), context)
        let filterElement = this.resolveUrlRef(style.get("filter"), context)
        let clip = style.clipRect()
        let filtered = filterElement.isSome()
        let elementBlend = svgMixBlendModeOf(style)
        let isolated = style.get("isolation") == Some("isolate")
        if (filtered) {
            this.appendFilteredGroupBegin(
                commands,
                shape.tag,
                matrix,
                style.opacity(),
                clipPath,
                maskElement,
                context.clipRect,
                filterElement,
                bounds,
                clip,
                context.clipQuads,
                blendMode: elementBlend
            )
        }
        let elementGroup = !filtered && (elementBlend != SvgMixBlendMode.Normal || isolated)
        if (elementGroup) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.GroupBegin,
                    shape.tag,
                    matrix,
                    opacity: style.opacity(),
                    bounds: bounds,
                    blendMode: elementBlend,
                    isolated: isolated
                )
            )
        }
        let grouped = filtered || elementGroup
        let paintOrder = svgPaintOrderOf(style.get("paint-order"))
        let fillCommands = ArrayList<SvgDisplayCommand>()
        let strokeCommands = ArrayList<SvgDisplayCommand>()
        let markerCommands = ArrayList<SvgDisplayCommand>()
        let fill = resolveContextPaintOf(
            style.fill(),
            context.contextFill,
            SvgPaintKind.ContextFill,
            "context-fill",
            this.warnings
        )
        if (fill.kind != SvgPaintKind.None) {
            fillCommands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.FillPath,
                    shape.tag,
                    matrix,
                    path: Some(path),
                    style: Some(style),
                    bounds: bounds,
                    opacity: if (grouped) { 1.0 } else { style.opacity() },
                    clipPath: if (filtered) { Option<SvgElement>.None } else { clipPath },
                    mask: if (filtered) { Option<SvgElement>.None } else { maskElement },
                    clipRect: if (filtered) { Option<SvgBounds>.None } else { context.clipRect },
                    filter: Option<SvgElement>.None,
                    clip: if (filtered) { Option<SvgClipRect>.None } else { clip },
                    clipQuads: context.clipQuads,
                    paintOverride: Some(fill)
                )
            )
        }
        let stroke = resolveContextPaintOf(
            style.stroke(),
            context.contextStroke,
            SvgPaintKind.ContextStroke,
            "context-stroke",
            this.warnings
        )
        if (stroke.kind != SvgPaintKind.None) {
            strokeCommands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.StrokePath,
                    shape.tag,
                    matrix,
                    path: Some(path),
                    style: Some(style),
                    bounds: bounds,
                    opacity: if (grouped) { 1.0 } else { style.opacity() },
                    clipPath: if (filtered) { Option<SvgElement>.None } else { clipPath },
                    mask: if (filtered) { Option<SvgElement>.None } else { maskElement },
                    clipRect: if (filtered) { Option<SvgBounds>.None } else { context.clipRect },
                    filter: Option<SvgElement>.None,
                    clip: if (filtered) { Option<SvgClipRect>.None } else { clip },
                    nonScalingStroke: style.vectorEffects().contains(
                        SvgVectorEffect.NonScalingStroke
                    ),
                    clipQuads: context.clipQuads,
                    paintOverride: Some(stroke)
                )
            )
        }
        this.addMarkers(shape, context, markerCommands, style)
        for (layer in paintOrder.layers) {
            match (layer) {
                case Fill => for (command in fillCommands) {
                    commands.add(command)
                }
                case Stroke => for (command in strokeCommands) {
                    commands.add(command)
                }
                case Markers => for (command in markerCommands) {
                    commands.add(command)
                }
            }
        }
        if (grouped) {
            commands.add(SvgDisplayCommand(SvgDisplayCommandKind.GroupEnd, shape.tag, matrix))
        }
    }

    private func appendFilteredGroupBegin(
        commands: ArrayList<SvgDisplayCommand>,
        tag: String,
        matrix: SvgMatrix,
        opacity: Float64,
        clipPath: ?SvgElement,
        mask: ?SvgElement,
        clipRect: ?SvgBounds,
        filter: ?SvgElement,
        bounds: ?SvgBounds,
        clip: ?SvgClipRect,
        clipQuads: Array<Array<SvgPoint>>,
        blendMode!: SvgMixBlendMode = SvgMixBlendMode.Normal
    ): Unit {
        commands.add(
            SvgDisplayCommand(
                SvgDisplayCommandKind.GroupBegin,
                tag,
                matrix,
                opacity: opacity,
                clipPath: clipPath,
                mask: mask,
                clipRect: clipRect,
                bounds: bounds,
                filter: filter,
                clip: clip,
                clipQuads: clipQuads,
                blendMode: blendMode
            )
        )
    }

    private func addMarkers(
        shape: SvgShape,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        if (style.get("marker-start").isNone() && style.get("marker-mid").isNone() &&
            style.get("marker-end").isNone()) {
            return
        }
        let expander = SvgMarkerExpander(root: Some(context.root))
        let instances = expander.expand(shape, style)
        for (warning in expander.warnings) {
            this.warnings.add(warning)
        }
        if (instances.size == 0) {
            return
        }
        let base = context.matrix.multiply(
            elementTransformMatrix(
                shape,
                style: style,
                viewportWidth: context.width,
                viewportHeight: context.height
            )
        )
        let sessionGuard = this.ensureGuard()
        for (instance in instances) {
            let label = svgRenderGuardLabel(
                "marker",
                instance.marker.attr("id") ?? "",
                svgElementPath(Some(context.root), instance.marker)
            )
            if (!sessionGuard.enter(instance.marker.identity, label, this.warnings)) {
                continue
            }
            let expanded = ArrayList<SvgDisplayCommand>()
            let overflowVisible = match (context.styles.get(instance.marker)) {
                case Some(style) => !style.overflowMode().clips()
                case None => false
            }
            // refX/refY 在内容坐标中定义；含 viewBox 时视口平移量是 C(refX, refY)。
            let contentTransform = markerViewBoxMatrix(instance.marker)
            let reference = contentTransform.apply(
                SvgPoint(
                    (instance.marker.refX ?? SvgLength(0.0)).value,
                    (instance.marker.refY ?? SvgLength(0.0)).value
                )
            )
            let viewportMatrix = base.multiply(instance.viewportMatrix)
                .multiply(SvgMatrix.translate(-reference.x, -reference.y))
            let contentFits = markerContentFits(
                instance.marker,
                instance.viewportWidth,
                instance.viewportHeight,
                contentTransform,
                context.styles
            )
            let markerClip: ?SvgBounds = if (overflowVisible || contentFits) {
                None
            } else {
                let clip = transformedRectBounds(
                    viewportMatrix,
                    0.0,
                    0.0,
                    instance.viewportWidth,
                    instance.viewportHeight
                )
                Some(match (context.clipRect) {
                    case Some(existing) => existing.intersect(clip)
                    case None => clip
                })
            }
            var markerQuads = context.clipQuads
            if (!overflowVisible && !contentFits && !isAxisAlignedMatrix(viewportMatrix)) {
                markerQuads = appendSvgQuad(
                    markerQuads,
                    transformedRectQuad(
                        viewportMatrix,
                        0.0,
                        0.0,
                        instance.viewportWidth,
                        instance.viewportHeight
                    )
                )
            }
            try {
                let list = this.buildContent(
                    instance.marker,
                    Int64(context.width),
                    Int64(context.height),
                    base.multiply(instance.matrix),
                    context.fonts,
                    root: Some(context.root),
                    clipRect: markerClip,
                    clipQuads: markerQuads
                )
                for (command in list.commands) {
                    expanded.add(command)
                }
            } finally {
                sessionGuard.leave()
            }
            for (command in expanded) {
                commands.add(command)
            }
        }
    }

    private func addImage(
        image: SvgImage,
        context: SvgRenderTreeContext,
        commands: ArrayList<SvgDisplayCommand>,
        style: SvgComputedStyle
    ): Unit {
        let x = lengthOrZero(svgStyledLength(Some(style), "x", image.x))
        let y = lengthOrZero(svgStyledLength(Some(style), "y", image.y))
        let width = lengthOrZero(svgStyledLength(Some(style), "width", image.width))
        let height = lengthOrZero(svgStyledLength(Some(style), "height", image.height))
        match (image.href) {
            case None => this.warnings.add("<image> 缺少 href，使用占位矩形")
            case Some(value) =>
                let trimmed = value.trimAscii()
                if (trimmed.size > 0 && trimmed[0] == b'#') {
                    this.warnings.add("<image> 的 href 为片段引用，不能作为图像资源，使用占位矩形")
                }
        }
        let box = SvgBounds(x, y, width, height)
        let matrix = context.matrix.multiply(
            elementTransformMatrix(
                image,
                style: style,
                bounds: box,
                viewportWidth: context.width,
                viewportHeight: context.height
            )
        )
        let clipPath = this.resolveUrlRef(style.get("clip-path"), context)
        let maskElement = this.resolveUrlRef(style.get("mask"), context)
        let filterElement = this.resolveUrlRef(style.get("filter"), context)
        let clip = style.clipRect()
        let filtered = filterElement.isSome()
        let elementBlend = svgMixBlendModeOf(style)
        let isolated = style.get("isolation") == Some("isolate")
        if (filtered) {
            this.appendFilteredGroupBegin(
                commands,
                "image",
                matrix,
                style.opacity(),
                clipPath,
                maskElement,
                context.clipRect,
                filterElement,
                Some(box),
                clip,
                context.clipQuads,
                blendMode: elementBlend
            )
        }
        let elementGroup = !filtered && (elementBlend != SvgMixBlendMode.Normal || isolated)
        if (elementGroup) {
            commands.add(
                SvgDisplayCommand(
                    SvgDisplayCommandKind.GroupBegin,
                    "image",
                    matrix,
                    opacity: style.opacity(),
                    bounds: Some(box),
                    blendMode: elementBlend,
                    isolated: isolated
                )
            )
        }
        let grouped = filtered || elementGroup
        commands.add(
            SvgDisplayCommand(
                SvgDisplayCommandKind.Image,
                "image",
                matrix,
                style: Some(style),
                bounds: Some(box),
                opacity: if (grouped) { 1.0 } else { style.opacity() },
                clipPath: if (filtered) { Option<SvgElement>.None } else { clipPath },
                mask: if (filtered) { Option<SvgElement>.None } else { maskElement },
                clipRect: if (filtered) { Option<SvgBounds>.None } else { context.clipRect },
                href: image.href,
                aspect: image.preserveAspectRatio,
                filter: Option<SvgElement>.None,
                clip: if (filtered) { Option<SvgClipRect>.None } else { clip },
                clipQuads: context.clipQuads
            )
        )
        if (grouped) {
            commands.add(SvgDisplayCommand(SvgDisplayCommandKind.GroupEnd, "image", matrix))
        }
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

private func elementTransformMatrix(
    element: SvgElement,
    style!: ?SvgComputedStyle = None,
    bounds!: ?SvgBounds = None,
    viewportWidth!: Float64 = 0.0,
    viewportHeight!: Float64 = 0.0
): SvgMatrix {
    effectiveElementTransform(
        element,
        style: style,
        bounds: bounds,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight
    )
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

/** 用户空间矩形经矩阵变换后的轴对齐包围盒（四角）。 */
private func transformedRectBounds(
    matrix: SvgMatrix,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64
): SvgBounds {
    let c0 = matrix.apply(SvgPoint(x, y))
    let c1 = matrix.apply(SvgPoint(x + width, y))
    let c2 = matrix.apply(SvgPoint(x + width, y + height))
    let c3 = matrix.apply(SvgPoint(x, y + height))
    let minimumX = min(min(c0.x, c1.x), min(c2.x, c3.x))
    let maximumX = max(max(c0.x, c1.x), max(c2.x, c3.x))
    let minimumY = min(min(c0.y, c1.y), min(c2.y, c3.y))
    let maximumY = max(max(c0.y, c1.y), max(c2.y, c3.y))
    SvgBounds(minimumX, minimumY, maximumX - minimumX, maximumY - minimumY)
}

/**
 * marker 内容是否全部落在 viewport 内；用于避免对无需裁剪的内容加蒙版。
 *
 * `contentTransform` 是 viewBox / preserveAspectRatio 建立的内容→视口矩阵；
 * 子元素包围盒先变换到视口坐标，再与 0..width / 0..height 比较。
 * 任何无法确定绘制范围的元素（描边、滤镜、裁剪、蒙版、文本、子元素 marker 等）
 * 都回退为需要裁剪。
 */
private func markerContentFits(
    marker: SvgElement,
    width: Float64,
    height: Float64,
    contentTransform: SvgMatrix,
    styles: SvgComputedStyleTree
): Bool {
    markerContentFitsIn(marker, contentTransform, width, height, styles)
}

private func markerContentFitsIn(
    element: SvgElement,
    matrix: SvgMatrix,
    width: Float64,
    height: Float64,
    styles: SvgComputedStyleTree
): Bool {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                if (child.tag == "title" || child.tag == "desc" || child.tag == "metadata") {
                    continue
                }
                let style = match (styles.get(child)) {
                    case Some(value) => value
                    case None => return false
                }
                if (markerStyleHasEffect(style, "filter") ||
                    markerStyleHasEffect(style, "clip-path") ||
                    markerStyleHasEffect(style, "mask") ||
                    markerStyleHasEffect(style, "clip") ||
                    markerStyleHasEffect(style, "marker-start") ||
                    markerStyleHasEffect(style, "marker-mid") ||
                    markerStyleHasEffect(style, "marker-end")) {
                    // 子元素自身的 marker 会扩展绘制范围，无法只凭路径包围盒判定。
                    return false
                }
                var childBounds: ?SvgBounds = Option<SvgBounds>.None
                match (child) {
                    case shape: SvgShape =>
                        if (style.stroke().kind != SvgPaintKind.None) {
                            return false
                        }
                        let path = match (elementPathData(shape)) {
                            case Some(value) => value
                            case None => return false
                        }
                        childBounds = match (pathDataBounds(path)) {
                            case Some(value) => Some(value)
                            case None => return false
                        }
                    case container: SvgContainer =>
                        childBounds = svgBBoxOf(
                            container,
                            SvgBBoxRequest(
                                SvgBBoxOptions(),
                                styles,
                                viewportWidth: width,
                                viewportHeight: height
                            )
                        )
                    case _ => return false
                }
                let childMatrix = matrix.multiply(effectiveElementTransform(
                    child,
                    style: Some(style),
                    bounds: childBounds,
                    viewportWidth: width,
                    viewportHeight: height
                ))
                match (child) {
                    case shape: SvgShape =>
                        let box = match (childBounds) {
                            case Some(value) => value
                            case None => return false
                        }
                        let corners: Array<SvgPoint> = [
                            childMatrix.apply(SvgPoint(box.x, box.y)),
                            childMatrix.apply(SvgPoint(box.x + box.width, box.y)),
                            childMatrix.apply(SvgPoint(box.x + box.width, box.y + box.height)),
                            childMatrix.apply(SvgPoint(box.x, box.y + box.height))
                        ]
                        for (point in corners) {
                            if (point.x < -1.0e-6 || point.y < -1.0e-6 ||
                                point.x > width + 1.0e-6 || point.y > height + 1.0e-6) {
                                return false
                            }
                        }
                    case container: SvgContainer =>
                        if (!markerContentFitsIn(
                            container,
                            childMatrix,
                            width,
                            height,
                            styles
                        )) {
                            return false
                        }
                    case _ => return false
                }
            case _ => ()
        }
    }
    true
}

private func markerStyleHasEffect(style: SvgComputedStyle, name: String): Bool {
    match (style.get(name)) {
        case Some(value) =>
            let text = value.trimAscii().toAsciiLower()
            text.size > 0 && text != "none" && text != "auto"
        case None => false
    }
}

private func transformedRectQuad(
    matrix: SvgMatrix,
    x: Float64,
    y: Float64,
    width: Float64,
    height: Float64
): Array<SvgPoint> {
    [
        matrix.apply(SvgPoint(x, y)),
        matrix.apply(SvgPoint(x + width, y)),
        matrix.apply(SvgPoint(x + width, y + height)),
        matrix.apply(SvgPoint(x, y + height))
    ]
}

private func isAxisAlignedMatrix(matrix: SvgMatrix): Bool {
    abs(matrix.b) < 1.0e-9 && abs(matrix.c) < 1.0e-9
}

private func appendSvgQuad(
    quads: Array<Array<SvgPoint>>,
    quad: Array<SvgPoint>
): Array<Array<SvgPoint>> {
    let result = ArrayList<Array<SvgPoint>>()
    for (value in quads) {
        result.add(value)
    }
    result.add(quad)
    result.toArray()
}

private func maxInt64(first: Int64, second: Int64): Int64 {    if (first > second) { first } else { second }
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

/** 把一组指令的包围盒换算到 `groupMatrix` 的本地空间并求并集。 */
private func unionCommandBounds(
    commands: ArrayList<SvgDisplayCommand>,
    groupMatrix: SvgMatrix
): ?SvgBounds {
    let inverse = groupMatrix.invert()
    var result: ?SvgBounds = None
    for (command in commands) {
        let box = match (command.bounds) {
            case Some(value) => value
            case None => continue
        }
        let relative = match (inverse) {
            case Some(value) => value.multiply(command.matrix)
            case None => command.matrix
        }
        let c0 = relative.apply(SvgPoint(box.x, box.y))
        let c1 = relative.apply(SvgPoint(box.x + box.width, box.y))
        let c2 = relative.apply(SvgPoint(box.x + box.width, box.y + box.height))
        let c3 = relative.apply(SvgPoint(box.x, box.y + box.height))
        let minimumX = min(min(c0.x, c1.x), min(c2.x, c3.x))
        let maximumX = max(max(c0.x, c1.x), max(c2.x, c3.x))
        let minimumY = min(min(c0.y, c1.y), min(c2.y, c3.y))
        let maximumY = max(max(c0.y, c1.y), max(c2.y, c3.y))
        let converted = SvgBounds(minimumX, minimumY, maximumX - minimumX, maximumY - minimumY)
        result = Some(match (result) {
            case Some(existing) => existing.union(converted)
            case None => converted
        })
    }
    result
}

/** 按构建器的 `/tag[i]` 规则给出元素路径；用于 warning 定位。 */
internal func svgElementPath(root: ?SvgElement, target: SvgElement): String {
    match (root) {
        case Some(node) =>
            let base = "/${node.tag}[1]"
            if (node.identity == target.identity) {
                return base
            }
            match (findSvgElementPath(node, target, base)) {
                case Some(value) => value
                case None => base
            }
        case None => "/${target.tag}[1]"
    }
}

private func findSvgElementPath(
    parent: SvgElement,
    target: SvgElement,
    path: String
): ?String {
    let counters = HashMap<String, Int64>()
    for (node in parent.children) {
        match (node) {
            case ElementNode(child) =>
                let tag = child.tag
                let index = (counters.get(tag) ?? 0) + 1
                counters[tag] = index
                let childPath = "${path}/${tag}[${index}]"
                if (child.identity == target.identity) {
                    return Some(childPath)
                }
                match (findSvgElementPath(child, target, childPath)) {
                    case Some(value) => return Some(value)
                    case None => ()
                }
            case _ => ()
        }
    }
    None
}


/** 以选项注册表为基座，把 `@font-face` 别名带入本次渲染。 */
private func deriveRenderFonts(
    fonts: ?SvgFontRegistry,
    faces: ArrayList<CssFontFaceRule>,
    warnings: ArrayList<String>
): SvgFontRegistry {
    let base = match (fonts) {
        case Some(value) => value
        case None => SvgFontRegistry.defaultRegistry()
    }
    SvgFontRegistry.derived(base, faces.toArray(), warnings: warnings)
}


/** 计算样式中的长度值；缺失或非长度返回 0。 */
private func svgStyledLengthOrZero(style: SvgComputedStyle, name: String): Float64 {
    match (style.get(name)) {
        case Some(text) => lengthOrZero(SvgLength.tryParse(text))
        case None => 0.0
    }
}

/** 外部 `use` 的解析结果：目标元素、其样式树、文档根与嵌套深度。 */
private class SvgExternalResolution {
    let element: SvgElement
    let styles: SvgComputedStyleTree
    let root: SvgElement
    let depth: Int64

    init(element: SvgElement, styles: SvgComputedStyleTree, root: SvgElement, depth: Int64) {
        this.element = element
        this.styles = styles
        this.root = root
        this.depth = depth
    }
}

/** 外部文档的 href 片段；无 `#` 返回空串。 */
private func svgHrefFragment(href: String): String {
    let bytes = href.unsafeBytes()
    for (index in 0..bytes.size) {
        if (bytes[index] == b'#') {
            return href[index + 1..]
        }
    }
    ""
}

/**
 * 外部文档的解析选项。
 *
 * 外部文档内部的不安全内容（含外部 `href`）一律按 `Remove` 处理并记 warning，
 * 不随调用方的 `Reject` / `Keep` 改变；其余安全上限与 `strict` 沿用主文档。
 * 同时强制关闭外部引用，确保不会因外部文档中的引用再次调用 provider。
 */
private func svgExternalParseOptions(base: SvgParseOptions): SvgParseOptions {
    let source = base.security
    let security = SvgSecurityOptions(
        unsafePolicy: SvgUnsafePolicy.Remove,
        allowScript: source.allowScript,
        allowEventAttributes: source.allowEventAttributes,
        allowExternalReferences: false,
        allowDataImages: source.allowDataImages,
        maxElements: source.maxElements,
        maxDepth: source.maxDepth,
        maxDecompressedBytes: source.maxDecompressedBytes
    )
    SvgParseOptions(strict: base.strict, security: security, xml: base.xml)
}

/** 新增 vector-effect 值对累积矩阵的修正；旧值与 none 原样返回。 */
private func svgApplyM6VectorEffects(
    matrix: SvgMatrix,
    style: SvgComputedStyle,
    local: SvgMatrix
): SvgMatrix {
    let effects = style.vectorEffects()
    var applies = false
    for (effect in effects) {
        match (effect.toString()) {
            case "none" | "non-scaling-stroke" => ()
            case _ => applies = true
        }
    }
    if (!applies) {
        return matrix
    }
    SvgVectorEffect2.apply(matrix, effects, local: local)
}
