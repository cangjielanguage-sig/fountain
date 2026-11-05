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
    let bitmap: SvgBitmap
    let opacity: Float64
    let clipPath: ?SvgElement
    let mask: ?SvgElement
    let clipRect: ?SvgBounds
    let matrix: SvgMatrix
    let bounds: ?SvgBounds

    init(
        bitmap: SvgBitmap,
        opacity: Float64,
        clipPath: ?SvgElement,
        mask: ?SvgElement,
        clipRect: ?SvgBounds,
        matrix: SvgMatrix,
        bounds: ?SvgBounds
    ) {
        this.bitmap = bitmap
        this.opacity = opacity
        this.clipPath = clipPath
        this.mask = mask
        this.clipRect = clipRect
        this.matrix = matrix
        this.bounds = bounds
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

    public init(options!: SvgRenderOptions = SvgRenderOptions()) {
        this.options = options
    }

    public func render(document: SvgDocument): SvgBitmap {
        let builder = SvgRenderTreeBuilder()
        let list = builder.build(document, options: this.options)
        for (warning in builder.warnings) {
            this.warnings.add(warning)
        }
        this.renderDisplayList(list)
    }

    public func render(element: SvgElement, width!: Int64, height!: Int64): SvgBitmap {
        let builder = SvgRenderTreeBuilder()
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

    private func renderDisplayList(list: SvgDisplayList): SvgBitmap {
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
                            command.bounds
                        )
                    )
                case GroupEnd =>
                    if (frames.size == 0) {
                        continue
                    }
                    let frame = frames[frames.size - 1]
                    frames.remove(at: frames.size - 1)
                    this.applyEffects(
                        frame.bitmap,
                        frame.clipRect,
                        frame.clipPath,
                        frame.mask,
                        frame.matrix,
                        frame.bounds,
                        list
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
                        command.mask.isSome()
                    if (needsLayer) {
                        let layer = SvgGroupCompositor.createLayer(list.width, list.height, this.options)
                        this.renderCommand(layer, command, list, registry)
                        this.applyEffects(
                            layer,
                            command.clipRect,
                            command.clipPath,
                            command.mask,
                            command.matrix,
                            command.bounds,
                            list
                        )
                        SvgGroupCompositor.composite(target, layer, 1.0)
                    } else {
                        this.renderCommand(target, command, list, registry)
                    }
            }
        }
        output
    }

    private func renderCommand(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        registry: SvgFontRegistry
    ): Unit {
        let style = match (command.style) {
            case Some(value) => value
            case None => return
        }
        match (command.kind) {
            case FillPath =>
                this.drawFill(bitmap, command, list, style)
            case StrokePath =>
                this.drawStroke(bitmap, command, list, style)
            case Text =>
                let text = match (command.textElement) {
                    case Some(value) => value
                    case None => return
                }
                let textRenderer = SvgTextRenderer(registry: registry)
                let outline = match (textRenderer.outline(text, style: style)) {
                    case Some(value) => value
                    case None => return
                }
                for (warning in textRenderer.warnings) {
                    this.warnings.add(warning)
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
                this.drawFill(bitmap, textCommand, list, style)
                this.drawStroke(bitmap, textCommand, list, style)
            case Image =>
                match (this.options.background) {
                    case Some(color) =>
                        match (command.bounds) {
                            case Some(box) =>
                                let path = rectPathData(box)
                                SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel).fill(
                                    path,
                                    matrix: command.matrix,
                                    color: color,
                                    fillRule: SvgFillRule.Nonzero,
                                    opacity: 1.0
                                )
                            case None => ()
                        }
                    case None => ()
                }
            case _ => ()
        }
    }

    private func drawFill(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle
    ): Unit {
        let path = match (command.path) {
            case Some(value) => value
            case None => return
        }
        let paint = style.fill()
        let opacity = command.opacity * style.fillOpacity()
        this.drawPaint(bitmap, command, list, style, path, paint, opacity, false)
    }

    private func drawStroke(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle
    ): Unit {
        let path = match (command.path) {
            case Some(value) => value
            case None => return
        }
        let paint = style.stroke()
        let opacity = command.opacity * style.strokeOpacity()
        this.drawPaint(bitmap, command, list, style, path, paint, opacity, true)
    }

    private func drawPaint(
        bitmap: SvgBitmap,
        command: SvgDisplayCommand,
        list: SvgDisplayList,
        style: SvgComputedStyle,
        path: SvgPathData,
        paint: SvgPaint,
        opacity: Float64,
        isStroke: Bool
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
                        let raster = SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel)
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
                    case None =>
                        this.warnings.add("画笔引用「#${id}」不存在")
                        match (paint.fallback) {
                            case Some(fallback) =>
                                this.drawPaint(bitmap, command, list, style, path, fallback, opacity, isStroke)
                                return
                            case None => return
                        }
                }
        }
        let raster = SvgRasterizer(bitmap, samplesPerPixel: this.options.samplesPerPixel)
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
        list: SvgDisplayList
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
                    targetBox: targetBox
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
                    targetBox: targetBox
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
