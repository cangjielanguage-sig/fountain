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

private class SvgRenderFrame {
    var bitmap: SvgBitmap
    let opacity: Float64
    let clipPath: ?SvgElement
    let mask: ?SvgElement
    let clipRect: ?SvgBounds
    let matrix: SvgMatrix
    let bounds: ?SvgBounds
    let filter: ?SvgElement

    init(
        bitmap: SvgBitmap,
        opacity: Float64,
        clipPath: ?SvgElement,
        mask: ?SvgElement,
        clipRect: ?SvgBounds,
        matrix: SvgMatrix,
        bounds: ?SvgBounds,
        filter: ?SvgElement
    ) {
        this.bitmap = bitmap
        this.opacity = opacity
        this.clipPath = clipPath
        this.mask = mask
        this.clipRect = clipRect
        this.matrix = matrix
        this.bounds = bounds
        this.filter = filter
    }
}

/**
 * 渲染入口：构建显示列表，再逐指令光栅化。
 *
 * 组透明度 / 裁剪 / 蒙版通过同尺寸离屏层实现；渲染器不读时间、随机数或环境变量。
 */
public class SvgRenderer {
    public let options: SvgRenderOptions
    public let warnings = ArrayList<String>()
    private let sessionImages: ?SvgImageResource
    private let sessionGuard: SvgRenderGuard

    public init(options!: SvgRenderOptions = SvgRenderOptions()) {
        this.options = options
        this.sessionImages = None
        this.sessionGuard = SvgRenderGuard()
    }

    /** 嵌套渲染（pattern tile / marker 内容）复用外层会话预算与引用守卫。 */
    internal init(
        options!: SvgRenderOptions,
        sessionImages!: SvgImageResource,
        sessionGuard!: SvgRenderGuard
    ) {
        this.options = options
        this.sessionImages = Some(sessionImages)
        this.sessionGuard = sessionGuard
    }

    public func render(document: SvgDocument): SvgBitmap {
        let builder = SvgRenderTreeBuilder()
        builder.attachGuard(this.sessionGuard)
        let list = builder.build(document, options: this.options)
        for (warning in builder.warnings) {
            this.warnings.add(warning)
        }
        this.renderDisplayList(list)
    }

    public func render(element: SvgElement, width!: Int64, height!: Int64): SvgBitmap {
        let builder = SvgRenderTreeBuilder()
        builder.attachGuard(this.sessionGuard)
        let list = builder.buildElement(element, width, height, options: this.options)
        for (warning in builder.warnings) {
            this.warnings.add(warning)
        }
        this.renderDisplayList(list)
    }

    /** 渲染为 PNG 字节。 */
    public func renderToPng(document: SvgDocument): Array<Byte> {
        this.render(document).toPngBytes()
    }

    internal func renderDisplayList(list: SvgDisplayList): SvgBitmap {
        this.options.validatePixels(list.width, list.height)
        let output = SvgBitmap(list.width, list.height)
        match (this.options.background) {
            case Some(color) => output.fill(color)
            case None => ()
        }
        let frames = ArrayList<SvgRenderFrame>()
        let registry = match (this.options.fonts) {
            case Some(value) => value
            case None => SvgFontRegistry.defaultRegistry()
        }
        let images = match (this.sessionImages) {
            case Some(value) => value
            case None => SvgImageResource(
                provider: this.options.images,
                budget: SvgDecodeBudget(SVG_MAX_RENDER_DECODE_PIXELS)
            )
        }
        let patterns = SvgPatternSampler(registry: this.options.fonts, root: Some(list.root))
        patterns.attachSession(this.sessionGuard, images)
        let filters = SvgFilterRenderer(registry: this.options.fonts)
        for (command in list.commands) {
            match (command.kind) {
                case GroupBegin =>
                    let layer = SvgGroupCompositor.createLayer(list.width, list.height, this.options)
                    frames.add(
                        SvgRenderFrame(
                            layer,
                            command.opacity,
                            command.clipPath,
                            command.mask,
                            command.clipRect,
                            command.matrix,
                            command.bounds,
                            command.filter
                        )
                    )
                case GroupEnd =>
                    if (frames.size == 0) {
                        continue
                    }
                    let frame = frames[frames.size - 1]
                    frames.remove(at: frames.size - 1)
                    match (frame.filter) {
                        case Some(filterElement) =>
                            match (filterElement) {
                                case filter: SvgFilter =>
                                    frame.bitmap = filters.apply(
                                        filter,
                                        frame.bitmap,
                                        frame.bounds ?? SvgBounds.empty(),
                                        frame.matrix,
                                        this.options
                                    )
                                case _ => ()
                            }
                        case None => ()
                    }
                    this.applyEffects(
                        frame.bitmap,
                        frame.clipRect,
                        frame.clipPath,
                        frame.mask,
                        frame.matrix,
                        frame.bounds,
                        list.root
                    )
                    let target = if (frames.size > 0) {
                        frames[frames.size - 1].bitmap
                    } else {
                        output
                    }
                    SvgGroupCompositor.composite(target, frame.bitmap, frame.opacity)
                case _ =>
                    let target = if (frames.size > 0) {
                        frames[frames.size - 1].bitmap
                    } else {
                        output
                    }
                    let needsLayer = command.clipRect.isSome() || command.clipPath.isSome() ||
                        command.mask.isSome() || command.filter.isSome()
                    if (needsLayer) {
                        var layer = SvgGroupCompositor.createLayer(list.width, list.height, this.options)
                        this.renderCommand(layer, command, list, registry, images, patterns)
                        match (command.filter) {
                            case Some(filterElement) =>
                                match (filterElement) {
                                    case filter: SvgFilter =>
                                        layer = filters.apply(
                                            filter,
                                            layer,
                                            command.bounds ?? SvgBounds.empty(),
                                            command.matrix,
                                            this.options
                                        )
                                    case _ => ()
                                }
                            case None => ()
                        }
                        this.applyEffects(
                            layer,
                            command.clipRect,
                            command.clipPath,
                            command.mask,
                            command.matrix,
                            command.bounds,
                            list.root
                        )
                        SvgGroupCompositor.composite(target, layer, 1.0)
                    } else {
                        this.renderCommand(target, command, list, registry, images, patterns)
                    }
            }
        }
        for (warning in patterns.warnings) {
            this.warnings.add(warning)
        }
        for (warning in filters.warnings) {
            this.warnings.add(warning)
        }
        output
    }

    private func renderCommand(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        registry: SvgFontRegistry,
        images: SvgImageResource,
        patterns: SvgPatternSampler
    ): Unit {
        let style = match (command.style) {
            case Some(value) => value
            case None => return
        }
        match (command.kind) {
            case FillPath =>
                this.drawFill(bitmap, command, list, style, patterns)
            case StrokePath =>
                this.drawStroke(bitmap, command, list, style, patterns)
            case Text =>
                let text = match (command.textElement) {
                    case Some(value) => value
                    case None => return
                }
                let textRenderer = SvgTextRenderer(registry: registry)
                let layout = textRenderer.outline(text, style: style, root: Some(list.root))
                for (warning in textRenderer.warnings) {
                    this.warnings.add(warning)
                }
                let outline = match (layout) {
                    case Some(value) => value
                    case None => return
                }
                let textCommand = SvgDisplayCommand(
                    SvgDisplayCommandKind.FillPath,
                    command.tag,
                    command.matrix,
                    path: Some(outline),
                    style: Some(style),
                    bounds: command.bounds,
                    opacity: command.opacity
                )
                this.drawFill(bitmap, textCommand, list, style, patterns)
                this.drawStroke(bitmap, textCommand, list, style, patterns)
            case Image =>
                let box = match (command.bounds) {
                    case Some(value) => value
                    case None => return
                }
                var loaded: ?SvgBitmap = None
                match (command.href) {
                    case Some(href) => loaded = images.load(href)
                    case None => ()
                }
                match (loaded) {
                    case Some(source) =>
                        drawImage(
                            bitmap,
                            command,
                            style,
                            box,
                            source
                        )
                    case None =>
                        this.warnings.add(
                            "元素「${command.tag}」的 <image> 资源不可用，已绘制占位（href=${command.href ?? ""}）"
                        )
                        match (this.options.background) {
                            case Some(color) =>
                                let path = rectPathData(box)
                                SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel, antiAlias: this.options.antiAlias).fill(
                                    path,
                                    matrix: command.matrix,
                                    color: color,
                                    fillRule: SvgFillRule.Nonzero,
                                    opacity: 1.0
                                )
                            case None => ()
                        }
                }
            case _ => ()
        }
    }

    private func drawFill(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle,
        patterns: SvgPatternSampler
    ): Unit {
        let path = match (command.path) {
            case Some(value) => value
            case None => return
        }
        let paint = style.fill()
        let opacity = command.opacity * style.fillOpacity()
        this.drawPaint(bitmap, command, list, style, path, paint, opacity, false, patterns)
    }

    private func drawStroke(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle,
        patterns: SvgPatternSampler
    ): Unit {
        let path = match (command.path) {
            case Some(value) => value
            case None => return
        }
        let paint = style.stroke()
        let opacity = command.opacity * style.strokeOpacity()
        this.drawPaint(bitmap, command, list, style, path, paint, opacity, true, patterns)
    }

    private func drawPaint(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle,
        path: SvgPathData,
        paint: SvgPaint,
        opacity: Float64,
        isStroke: Bool,
        patterns: SvgPatternSampler
    ): Unit {
        if (opacity <= 0.0) {
            return
        }
        let color = match (paint.kind) {
            case None => return
            case CurrentColor => style.color()
            case Color => paint.color ?? SvgColor.Black
            case Reference =>
                let id = match (paint.reference) {
                    case Some(value) => stripSvgHash(value)
                    case None => ""
                }
                let gradient = findGradientById(Some(list.root), id)
                match (gradient) {
                    case Some(found) =>
                        let box = command.bounds ?? SvgBounds.empty()
                        let raster = SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel, antiAlias: this.options.antiAlias)
                        if (isStroke) {
                            raster.strokeGradient(
                                path,
                                found,
                                box,
                                style.color(),
                                root: Some(list.root),
                                matrix: command.matrix,
                                strokeWidth: style.strokeWidth().value,
                                lineCap: style.strokeLineCap(),
                                lineJoin: style.strokeLineJoin(),
                                miterLimit: style.strokeMiterLimit(),
                                dashArray: strokeDashValues(style),
                                dashOffset: style.strokeDashOffset().value,
                                opacity: opacity
                            )
                        } else {
                            raster.fillGradient(
                                path,
                                found,
                                box,
                                style.color(),
                                root: Some(list.root),
                                matrix: command.matrix,
                                fillRule: style.fillRule(),
                                opacity: opacity
                            )
                        }
                        return
                    case None => ()
                }
                let pattern = findPatternById(Some(list.root), id)
                match (pattern) {
                    case Some(found) =>
                        let box = command.bounds ?? SvgBounds.empty()
                        let tile = match (patterns.sampleTile(found, box, this.options)) {
                            case Some(value) => value
                            case None => return
                        }
                        let raster = SvgRasterizer(
                            bitmap,
                            samplesPerPixel: this.options.samplesPerPixel,
                            antiAlias: this.options.antiAlias
                        )
                        let inverse = match (command.matrix.invert()) {
                            case Some(value) => value
                            case None => SvgMatrix.identity
                        }
                        let shader = { x: Int64, y: Int64 =>
                            tile.colorAt(inverse.apply(SvgPoint(Float64(x) + 0.5, Float64(y) + 0.5)))
                        }
                        if (isStroke) {
                            let userContours = flattenPathData(path, SvgMatrix.identity, 0.25)
                            let strokeStyle = SvgStrokeStyle(
                                style.strokeWidth().value,
                                lineCap: style.strokeLineCap(),
                                lineJoin: style.strokeLineJoin(),
                                miterLimit: style.strokeMiterLimit(),
                                dashArray: strokeDashValues(style),
                                dashOffset: style.strokeDashOffset().value
                            )
                            let outlines = SvgStrokeOutliner.outlineContours(userContours, strokeStyle)
                            let transformed = ArrayList<Array<SvgPoint>>()
                            for (contour in outlines) {
                                let points = ArrayList<SvgPoint>()
                                for (point in contour) {
                                    points.add(command.matrix.apply(point))
                                }
                                transformed.add(points.toArray())
                            }
                            raster.fillContoursShader(
                                transformed.toArray(),
                                SvgFillRule.Nonzero,
                                opacity,
                                shader
                            )
                        } else {
                            let contours = flattenPathData(path, command.matrix, 0.25)
                            raster.fillContoursShader(contours, style.fillRule(), opacity, shader)
                        }
                        return
                    case None =>
                        this.warnings.add("画笔引用「#${id}」不存在")
                        match (paint.fallback) {
                            case Some(fallback) =>
                                this.drawPaint(
                                    bitmap, command, list, style, path, fallback, opacity, isStroke, patterns
                                )
                                return
                            case None => return
                        }
                }
        }
        let raster = SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel, antiAlias: this.options.antiAlias)
        if (isStroke) {
            raster.stroke(
                path,
                matrix: command.matrix,
                color: color,
                strokeWidth: style.strokeWidth().value,
                lineCap: style.strokeLineCap(),
                lineJoin: style.strokeLineJoin(),
                miterLimit: style.strokeMiterLimit(),
                dashArray: strokeDashValues(style),
                dashOffset: style.strokeDashOffset().value,
                opacity: opacity
            )
        } else {
            raster.fill(
                path,
                matrix: command.matrix,
                color: color,
                fillRule: style.fillRule(),
                opacity: opacity
            )
        }
    }

    private func applyEffects(
        bitmap: SvgBitmap,
        clipRect: ?SvgBounds,
        clipPath: ?SvgElement,
        maskElement: ?SvgElement,
        matrix: SvgMatrix,
        bounds: ?SvgBounds,
        root: SvgElement
    ): Unit {
        match (clipRect) {
            case Some(rect) => clipBitmapToRect(bitmap, rect)
            case None => ()
        }
        let targetBox = bounds ?? SvgBounds.empty()
        match (clipPath) {
            case Some(clip) =>
                let units = SvgCoordinateUnits.fromName(
                    (clip.attr("clipPathUnits") ?? "userSpaceOnUse").trimAscii()
                ) ?? SvgCoordinateUnits.UserSpaceOnUse
                let mask = SvgClipPathMasker.render(
                    clip,
                    bitmap.width,
                    bitmap.height,
                    samplesPerPixel: this.options.samplesPerPixel,
                    contentMatrix: matrix,
                    units: units,
                    targetBox: targetBox,
                    root: Some(root),
                    warnings: Some(this.warnings)
                )
                mask.applyTo(bitmap)
            case None => ()
        }
        match (maskElement) {
            case Some(maskElementValue) =>
                let maskUnits = SvgCoordinateUnits.fromName(
                    (maskElementValue.attr("maskUnits") ?? "objectBoundingBox").trimAscii()
                ) ?? SvgCoordinateUnits.ObjectBoundingBox
                let contentUnits = SvgCoordinateUnits.fromName(
                    (maskElementValue.attr("maskContentUnits") ?? "userSpaceOnUse").trimAscii()
                ) ?? SvgCoordinateUnits.UserSpaceOnUse
                let mask = SvgMasker.render(
                    maskElementValue,
                    bitmap.width,
                    bitmap.height,
                    samplesPerPixel: this.options.samplesPerPixel,
                    contentMatrix: matrix,
                    maskUnits: maskUnits,
                    maskContentUnits: contentUnits,
                    targetBox: targetBox,
                    root: Some(root),
                    warnings: Some(this.warnings)
                )
                mask.applyTo(bitmap)
            case None => ()
        }
    }
}

private func clipBitmapToRect(bitmap: SvgBitmap, rect: SvgBounds): Unit {
    for (y in 0..bitmap.height) {
        for (x in 0..bitmap.width) {
            if (Float64(x) + 0.5 < rect.x || Float64(y) + 0.5 < rect.y ||
                Float64(x) + 0.5 >= rect.x + rect.width || Float64(y) + 0.5 >= rect.y + rect.height) {
                let index = (y * bitmap.width + x) * 4 + 3
                bitmap.pixels[index] = 0
            }
        }
    }
}

private func strokeDashValues(style: SvgComputedStyle): Array<Float64> {
    let lengths = style.strokeDashArray()
    let values = ArrayList<Float64>()
    for (length in lengths) {
        values.add(length.value)
    }
    values.toArray()
}

private func rectPathData(box: SvgBounds): SvgPathData {
    SvgPathData([
        SvgPathCommand(SvgPathCommandKind.MoveTo, false, [box.x, box.y]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [box.x + box.width, box.y]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [box.x + box.width, box.y + box.height]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [box.x, box.y + box.height]),
        SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
    ])
}

/** 顶层 PNG 渲染便捷函数。 */
public func renderToPng(
    document: SvgDocument,
    options!: SvgRenderOptions = SvgRenderOptions()
): Array<Byte> {
    SvgRenderer(options: options).render(document).toPngBytes()
}


/** 源图 → 目标矩形的映射参数。 */
private struct SvgImageMapping {
    let scaleX: Float64
    let scaleY: Float64
    let offsetX: Float64
    let offsetY: Float64

    init(scaleX: Float64, scaleY: Float64, offsetX: Float64, offsetY: Float64) {
        this.scaleX = scaleX
        this.scaleY = scaleY
        this.offsetX = offsetX
        this.offsetY = offsetY
    }
}

private func imageMapping(
    boxWidth: Float64,
    boxHeight: Float64,
    sourceWidth: Float64,
    sourceHeight: Float64,
    aspect: ?SvgPreserveAspectRatio
): SvgImageMapping {
    let ratio = match (aspect) {
        case Some(value) => value
        case None => SvgPreserveAspectRatio.Default
    }
    if (ratio.align == SvgAspectAlign.NoAlign) {
        return SvgImageMapping(boxWidth / sourceWidth, boxHeight / sourceHeight, 0.0, 0.0)
    }
    let scaleX = boxWidth / sourceWidth
    let scaleY = boxHeight / sourceHeight
    let scale = if (ratio.slice) {
        max(scaleX, scaleY)
    } else {
        min(scaleX, scaleY)
    }
    let contentWidth = sourceWidth * scale
    let contentHeight = sourceHeight * scale
    let factorX = if (ratio.align.isXMin()) {
        0.0
    } else if (ratio.align.isXMax()) {
        1.0
    } else {
        0.5
    }
    let factorY = if (ratio.align.isYMin()) {
        0.0
    } else if (ratio.align.isYMax()) {
        1.0
    } else {
        0.5
    }
    SvgImageMapping(
        scale,
        scale,
        (boxWidth - contentWidth) * factorX,
        (boxHeight - contentHeight) * factorY
    )
}

private func drawImage(
    target: SvgBitmap,
    command: SvgDisplayCommand,
    style: SvgComputedStyle,
    box: SvgBounds,
    source: SvgBitmap
): Unit {
    if (box.width <= 0.0 || box.height <= 0.0) {
        return
    }
    let inverse = match (command.matrix.invert()) {
        case Some(value) => value
        case None => return
    }
    let c0 = command.matrix.apply(SvgPoint(box.x, box.y))
    let c1 = command.matrix.apply(SvgPoint(box.x + box.width, box.y))
    let c2 = command.matrix.apply(SvgPoint(box.x + box.width, box.y + box.height))
    let c3 = command.matrix.apply(SvgPoint(box.x, box.y + box.height))
    let minimumX = min(min(c0.x, c1.x), min(c2.x, c3.x))
    let maximumX = max(max(c0.x, c1.x), max(c2.x, c3.x))
    let minimumY = min(min(c0.y, c1.y), min(c2.y, c3.y))
    let maximumY = max(max(c0.y, c1.y), max(c2.y, c3.y))
    let startX = max(0, Int64(floor(minimumX)))
    let endX = min(target.width, Int64(ceil(maximumX)))
    let startY = max(0, Int64(floor(minimumY)))
    let endY = min(target.height, Int64(ceil(maximumY)))
    let rendering = style.imageRendering()
    let bilinear = rendering == SvgImageRendering.Auto || rendering == SvgImageRendering.OptimizeQuality
    let mapping = imageMapping(
        box.width,
        box.height,
        Float64(source.width),
        Float64(source.height),
        command.aspect
    )
    var py = startY
    while (py < endY) {
        var px = startX
        while (px < endX) {
            let local = inverse.apply(SvgPoint(Float64(px) + 0.5, Float64(py) + 0.5))
            let u = local.x - box.x
            let v = local.y - box.y
            if (u >= 0.0 && u < box.width && v >= 0.0 && v < box.height) {
                let sample = sampleImage(source, mapping, u, v, bilinear)
                if (sample[3] > 0) {
                    let alpha = Float64(sample[3]) / 255.0 * command.opacity
                    if (alpha > 0.0) {
                        target.blend(
                            px,
                            py,
                            SvgRgba(
                                Float64(sample[0]) / 255.0 * alpha,
                                Float64(sample[1]) / 255.0 * alpha,
                                Float64(sample[2]) / 255.0 * alpha,
                                alpha
                            )
                        )
                    }
                }
            }
            px++
        }
        py++
    }
}

private func sampleImage(
    source: SvgBitmap,
    mapping: SvgImageMapping,
    u: Float64,
    v: Float64,
    bilinear: Bool
): Array<Byte> {
    let transparent: Array<Byte> = [0, 0, 0, 0]
    let sourceX = (u - mapping.offsetX) / mapping.scaleX
    let sourceY = (v - mapping.offsetY) / mapping.scaleY
    if (sourceX < 0.0 || sourceY < 0.0 ||
        sourceX >= Float64(source.width) || sourceY >= Float64(source.height)) {
        return transparent
    }
    let result = Array<Byte>(4, repeat: 0)
    if (!bilinear) {
        let x = min(Int64(floor(sourceX)), source.width - 1)
        let y = min(Int64(floor(sourceY)), source.height - 1)
        let base = (y * source.width + x) * 4
        result[0] = source.pixels[base]
        result[1] = source.pixels[base + 1]
        result[2] = source.pixels[base + 2]
        result[3] = source.pixels[base + 3]
        return result
    }
    let centerX = sourceX - 0.5
    let centerY = sourceY - 0.5
    let floorX = Int64(floor(centerX))
    let floorY = Int64(floor(centerY))
    let fractionX = centerX - Float64(floorX)
    let fractionY = centerY - Float64(floorY)
    let x0 = clampImageIndex(floorX, source.width)
    let x1 = clampImageIndex(floorX + 1, source.width)
    let y0 = clampImageIndex(floorY, source.height)
    let y1 = clampImageIndex(floorY + 1, source.height)
    let weights: Array<Float64> = [
        (1.0 - fractionX) * (1.0 - fractionY),
        fractionX * (1.0 - fractionY),
        (1.0 - fractionX) * fractionY,
        fractionX * fractionY
    ]
    let columns: Array<Int64> = [x0, x1, x0, x1]
    let rows: Array<Int64> = [y0, y0, y1, y1]
    var alpha: Float64 = 0.0
    var red: Float64 = 0.0
    var green: Float64 = 0.0
    var blue: Float64 = 0.0
    for (index in 0..4) {
        let base = (rows[index] * source.width + columns[index]) * 4
        let weight = weights[index]
        let sampleAlpha = Float64(source.pixels[base + 3]) / 255.0
        alpha += sampleAlpha * weight
        red += Float64(source.pixels[base]) / 255.0 * sampleAlpha * weight
        green += Float64(source.pixels[base + 1]) / 255.0 * sampleAlpha * weight
        blue += Float64(source.pixels[base + 2]) / 255.0 * sampleAlpha * weight
    }
    if (alpha <= 0.0) {
        return transparent
    }
    result[0] = UInt8(Int64(round(clampSvgUnit(red / alpha) * 255.0)))
    result[1] = UInt8(Int64(round(clampSvgUnit(green / alpha) * 255.0)))
    result[2] = UInt8(Int64(round(clampSvgUnit(blue / alpha) * 255.0)))
    result[3] = UInt8(Int64(round(clampSvgUnit(alpha) * 255.0)))
    result
}

private func clampImageIndex(value: Int64, size: Int64): Int64 {
    if (value < 0) {
        return 0
    }
    if (value >= size) {
        return size - 1
    }
    value
}
