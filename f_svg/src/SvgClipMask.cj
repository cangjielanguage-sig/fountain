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

/** 8 位覆盖率蒙版：裁剪 / 蒙版共用。 */
public class SvgCoverageMask {
    public let width: Int64
    public let height: Int64
    public let coverage: Array<Byte>

    public init(width: Int64, height: Int64) {
        if (width <= 0 || height <= 0) {
            throw invalidValue("覆盖率蒙版尺寸必须为正")
        }
        this.width = width
        this.height = height
        this.coverage = Array<Byte>(width * height, repeat: 0)
    }

    public init(width: Int64, height: Int64, coverage: Array<Byte>) {
        if (width <= 0 || height <= 0 || coverage.size != width * height) {
            throw invalidValue("覆盖率蒙版尺寸与数据不匹配")
        }
        this.width = width
        this.height = height
        this.coverage = coverage
    }

    public func coverageAt(x: Int64, y: Int64): Int64 {
        if (x < 0 || y < 0 || x >= this.width || y >= this.height) {
            return 0
        }
        Int64(this.coverage[y * this.width + x])
    }

    public func multiply(that: SvgCoverageMask): SvgCoverageMask {
        if (this.width != that.width || this.height != that.height) {
            throw invalidValue("覆盖率蒙版尺寸不一致")
        }
        let result = Array<Byte>(this.coverage.size, repeat: 0)
        for (index in 0..this.coverage.size) {
            result[index] = UInt8(Int64(this.coverage[index]) * Int64(that.coverage[index]) / 255)
        }
        SvgCoverageMask(this.width, this.height, result)
    }

    /** 把蒙版乘到已绘制位图的 alpha 上。 */
    public func applyTo(bitmap: SvgBitmap): Unit {
        if (bitmap.width != this.width || bitmap.height != this.height) {
            throw invalidValue("蒙版与位图尺寸不一致")
        }
        for (index in 0..this.coverage.size) {
            let factor = Int64(this.coverage[index])
            let alphaIndex = index * 4 + 3
            bitmap.pixels[alphaIndex] = UInt8(Int64(bitmap.pixels[alphaIndex]) * factor / 255)
        }
    }
}

/** `clipPath` 覆盖率渲染。 */
public class SvgClipPathMasker {
    public static func render(
        clip: SvgElement,
        width: Int64,
        height: Int64,
        samplesPerPixel!: Int64 = 4,
        contentMatrix!: SvgMatrix = SvgMatrix.identity,
        units!: SvgCoordinateUnits = SvgCoordinateUnits.UserSpaceOnUse,
        targetBox!: SvgBounds = SvgBounds.empty(),
        root!: ?SvgElement = None,
        warnings!: ?ArrayList<String> = None,
        styles!: ?SvgComputedStyleTree = None,
        viewportWidth!: Float64 = 300.0,
        viewportHeight!: Float64 = 150.0
    ): SvgCoverageMask {
        let rootElement = root ?? rootOfSvgElement(clip)
        let warningList = warnings ?? ArrayList<String>()
        renderClipCoverage(
            clip,
            width,
            height,
            samplesPerPixel,
            contentMatrix,
            units,
            targetBox,
            rootElement,
            warningList,
            Array<String>(),
            0,
            styles,
            viewportWidth,
            viewportHeight
        )
    }
}

/** `mask` 的 luminance / alpha 蒙版渲染。 */
public class SvgMasker {
    public static func render(
        mask: SvgElement,
        width: Int64,
        height: Int64,
        samplesPerPixel!: Int64 = 4,
        contentMatrix!: SvgMatrix = SvgMatrix.identity,
        maskUnits!: SvgCoordinateUnits = SvgCoordinateUnits.ObjectBoundingBox,
        maskContentUnits!: SvgCoordinateUnits = SvgCoordinateUnits.UserSpaceOnUse,
        targetBox!: SvgBounds = SvgBounds.empty(),
        root!: ?SvgElement = None,
        warnings!: ?ArrayList<String> = None,
        styles!: ?SvgComputedStyleTree = None,
        viewportWidth!: Float64 = 300.0,
        viewportHeight!: Float64 = 150.0
    ): SvgCoverageMask {
        let rootElement = root ?? rootOfSvgElement(mask)
        let warningList = warnings ?? ArrayList<String>()
        renderMaskCoverage(
            mask,
            width,
            height,
            samplesPerPixel,
            contentMatrix,
            maskUnits,
            maskContentUnits,
            targetBox,
            rootElement,
            warningList,
            Array<String>(),
            0,
            styles,
            viewportWidth,
            viewportHeight
        )
    }
}

/** 组透明度与离屏层。 */
public class SvgGroupCompositor {
    /** 按 `maxPixels` 校验后创建离屏层。 */
    public static func createLayer(width: Int64, height: Int64, options: SvgRenderOptions): SvgBitmap {
        options.validatePixels(width, height)
        SvgBitmap(width, height)
    }

    /** 把整层按 `opacity` 合成到目标；非法 opacity 按 1 处理。 */
    public static func composite(destination: SvgBitmap, layer: SvgBitmap, opacity: Float64): Unit {
        SvgGroupCompositor.composite(destination, layer, opacity, mode: SvgMixBlendMode.Normal)
    }

    /**
     * 按 `mode` 把整层合成到目标。
     *
     * `normal` 走与 M4 完全相同的 `blend` 路径，保证逐字节一致；其余模式在预乘域
     * 计算混合色后写回。
     */
    public static func composite(
        destination: SvgBitmap,
        layer: SvgBitmap,
        opacity: Float64,
        mode!: SvgMixBlendMode
    ): Unit {
        let effective = if (!isFiniteSvgNumber(opacity) || opacity < 0.0 || opacity > 1.0) {
            1.0
        } else {
            opacity
        }
        if (effective <= 0.0) {
            return
        }
        for (y in 0..layer.height) {
            for (x in 0..layer.width) {
                let color = layer.pixel(x, y)
                if (color.alpha <= 0.0) {
                    continue
                }
                if (mode == SvgMixBlendMode.Normal) {
                    destination.blend(x, y, SvgRgba.fromColor(color, effective))
                } else {
                    let backdropColor = destination.pixel(x, y)
                    let backdropAlpha = backdropColor.alpha
                    let backdrop = SvgRgba(
                        Float64(backdropColor.red) / 255.0 * backdropAlpha,
                        Float64(backdropColor.green) / 255.0 * backdropAlpha,
                        Float64(backdropColor.blue) / 255.0 * backdropAlpha,
                        backdropAlpha
                    )
                    let result = blendSvgRgba(backdrop, SvgRgba.fromColor(color, effective), mode)
                    destination.setPixel(x, y, result.toColor())
                }
            }
        }
    }
}

private func bboxMatrix(box: SvgBounds): SvgMatrix {
    SvgMatrix.translate(box.x, box.y).multiply(SvgMatrix.scale(box.width, box.height))
}

private func renderClipCoverage(
    clip: SvgElement,
    width: Int64,
    height: Int64,
    samplesPerPixel: Int64,
    contentMatrix: SvgMatrix,
    units: SvgCoordinateUnits,
    targetBox: SvgBounds,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): SvgCoverageMask {
    let bitmap = SvgBitmap(width, height)
    var matrix = contentMatrix
    if (units == SvgCoordinateUnits.ObjectBoundingBox) {
        matrix = matrix.multiply(bboxMatrix(targetBox))
    }
    let fillRule = SvgFillRule.fromName((clip.attr("clip-rule") ?? "nonzero").trimAscii().toAsciiLower()) ??
        SvgFillRule.Nonzero
    renderClipChildren(
        clip,
        matrix,
        bitmap,
        fillRule,
        samplesPerPixel,
        root,
        warnings,
        stack,
        depth,
        styles,
        viewportWidth,
        viewportHeight
    )
    let coverage = Array<Byte>(width * height, repeat: 0)
    for (index in 0..coverage.size) {
        coverage[index] = bitmap.pixels[index * 4 + 3]
    }
    SvgCoverageMask(width, height, coverage)
}

private func renderMaskCoverage(
    mask: SvgElement,
    width: Int64,
    height: Int64,
    samplesPerPixel: Int64,
    contentMatrix: SvgMatrix,
    maskUnits: SvgCoordinateUnits,
    maskContentUnits: SvgCoordinateUnits,
    targetBox: SvgBounds,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): SvgCoverageMask {
    let bitmap = SvgBitmap(width, height)
    var content = contentMatrix
    if (maskContentUnits == SvgCoordinateUnits.ObjectBoundingBox) {
        content = content.multiply(bboxMatrix(targetBox))
    }
    renderMaskChildren(
        mask,
        content,
        bitmap,
        samplesPerPixel,
        root,
        warnings,
        stack,
        depth,
        styles,
        viewportWidth,
        viewportHeight
    )
    let region = maskRegion(mask, width, height, contentMatrix, maskUnits, targetBox)
    let alphaType = (mask.attr("mask-type") ?? "luminance").trimAscii().toAsciiLower() == "alpha"
    let coverage = Array<Byte>(width * height, repeat: 0)
    for (y in 0..height) {
        for (x in 0..width) {
            if (x < region.x || y < region.y || x >= region.x + region.width ||
                y >= region.y + region.height) {
                continue
            }
            let color = bitmap.pixel(x, y)
            let value = if (alphaType) {
                color.alpha
            } else {
                (0.2125 * Float64(color.red) + 0.7154 * Float64(color.green) +
                    0.0721 * Float64(color.blue)) / 255.0 * color.alpha
            }
            coverage[y * width + x] = quantizeSvgChannel(value)
        }
    }
    SvgCoverageMask(width, height, coverage)
}

private func renderClipChildren(
    element: SvgElement,
    matrix: SvgMatrix,
    bitmap: SvgBitmap,
    fillRule: SvgFillRule,
    samplesPerPixel: Int64,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                let childStyle = match (styles) {
                    case Some(tree) => tree.get(child)
                    case None => Option<SvgComputedStyle>.None
                }
                let childBounds = match (childStyle) {
                    case Some(value) => if (value.transformBox() == SvgTransformBox.FillBox) {
                        svgBBoxOf(
                            child,
                            SvgBBoxRequest(
                                SvgBBoxOptions(),
                                styles,
                                viewportWidth: viewportWidth,
                                viewportHeight: viewportHeight
                            )
                        )
                    } else {
                        Option<SvgBounds>.None
                    }
                    case None => Option<SvgBounds>.None
                }
                let childMatrix = matrix.multiply(
                    effectiveElementTransform(
                        child,
                        style: childStyle,
                        bounds: childBounds,
                        viewportWidth: viewportWidth,
                        viewportHeight: viewportHeight
                    )
                )
                let clipId = readEffectId(child.attr("clip-path"))
                let maskId = readEffectId(child.attr("mask"))
                let data = elementPathData(child, style: childStyle)
                if (clipId.isNone() && maskId.isNone()) {
                    match (data) {
                        case Some(path) =>
                            let rule = SvgFillRule.fromName(
                                (child.attr("clip-rule") ?? fillRule.attrName()).trimAscii().toAsciiLower()
                            ) ?? fillRule
                            SvgRasterizer(bitmap, samplesPerPixel: samplesPerPixel).fill(
                                path,
                                matrix: childMatrix,
                                color: SvgColor.Black,
                                fillRule: rule
                            )
                        case None => renderClipChildren(
                            child,
                            childMatrix,
                            bitmap,
                            fillRule,
                            samplesPerPixel,
                            root,
                            warnings,
                            stack,
                            depth,
                            styles,
                            viewportWidth,
                            viewportHeight
                        )
                    }
                    continue
                }
                let layer = SvgBitmap(bitmap.width, bitmap.height)
                match (data) {
                    case Some(path) =>
                        let rule = SvgFillRule.fromName(
                            (child.attr("clip-rule") ?? fillRule.attrName()).trimAscii().toAsciiLower()
                        ) ?? fillRule
                        SvgRasterizer(layer, samplesPerPixel: samplesPerPixel).fill(
                            path,
                            matrix: childMatrix,
                            color: SvgColor.Black,
                            fillRule: rule
                        )
                    case None => renderClipChildren(
                        child,
                        childMatrix,
                        layer,
                        fillRule,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                }
                let box = match (data) {
                    case Some(path) => pathDataBounds(path) ?? SvgBounds.empty()
                    case None => SvgBounds.empty()
                }
                match (clipId) {
                    case Some(id) => applyClipReference(
                        layer,
                        id,
                        childMatrix,
                        box,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                    case None => ()
                }
                match (maskId) {
                    case Some(id) => applyMaskReference(
                        layer,
                        id,
                        childMatrix,
                        box,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                    case None => ()
                }
                SvgGroupCompositor.composite(bitmap, layer, 1.0)
            case _ => ()
        }
    }
}

private func renderMaskChildren(
    element: SvgElement,
    matrix: SvgMatrix,
    bitmap: SvgBitmap,
    samplesPerPixel: Int64,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                let childStyle = match (styles) {
                    case Some(tree) => tree.get(child)
                    case None => Option<SvgComputedStyle>.None
                }
                let childBounds = match (childStyle) {
                    case Some(value) => if (value.transformBox() == SvgTransformBox.FillBox) {
                        svgBBoxOf(
                            child,
                            SvgBBoxRequest(
                                SvgBBoxOptions(),
                                styles,
                                viewportWidth: viewportWidth,
                                viewportHeight: viewportHeight
                            )
                        )
                    } else {
                        Option<SvgBounds>.None
                    }
                    case None => Option<SvgBounds>.None
                }
                let childMatrix = matrix.multiply(
                    effectiveElementTransform(
                        child,
                        style: childStyle,
                        bounds: childBounds,
                        viewportWidth: viewportWidth,
                        viewportHeight: viewportHeight
                    )
                )
                let clipId = readEffectId(child.attr("clip-path"))
                let maskId = readEffectId(child.attr("mask"))
                let data = elementPathData(child, style: childStyle)
                if (clipId.isNone() && maskId.isNone()) {
                    match (data) {
                        case Some(path) => drawMaskPath(child, path, childMatrix, bitmap, samplesPerPixel)
                        case None => renderMaskChildren(
                            child,
                            childMatrix,
                            bitmap,
                            samplesPerPixel,
                            root,
                            warnings,
                            stack,
                            depth,
                            styles,
                            viewportWidth,
                            viewportHeight
                        )
                    }
                    continue
                }
                let layer = SvgBitmap(bitmap.width, bitmap.height)
                match (data) {
                    case Some(path) => drawMaskPath(child, path, childMatrix, layer, samplesPerPixel)
                    case None => renderMaskChildren(
                        child,
                        childMatrix,
                        layer,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                }
                let box = match (data) {
                    case Some(path) => pathDataBounds(path) ?? SvgBounds.empty()
                    case None => SvgBounds.empty()
                }
                match (clipId) {
                    case Some(id) => applyClipReference(
                        layer,
                        id,
                        childMatrix,
                        box,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                    case None => ()
                }
                match (maskId) {
                    case Some(id) => applyMaskReference(
                        layer,
                        id,
                        childMatrix,
                        box,
                        samplesPerPixel,
                        root,
                        warnings,
                        stack,
                        depth,
                        styles,
                        viewportWidth,
                        viewportHeight
                    )
                    case None => ()
                }
                SvgGroupCompositor.composite(bitmap, layer, 1.0)
            case _ => ()
        }
    }
}

private func drawMaskPath(
    child: SvgElement,
    path: SvgPathData,
    matrix: SvgMatrix,
    bitmap: SvgBitmap,
    samplesPerPixel: Int64
): Unit {
    match (child) {
        case shape: SvgShape =>
            let paint = shape.fill ?? SvgPaint.of(SvgColor.Black)
            if (paint.kind == SvgPaintKind.Color) {
                match (paint.color) {
                    case Some(color) =>
                        let fillOpacity = shape.fillOpacity ?? 1.0
                        let opacity = shape.opacity ?? 1.0
                        let alpha = clampSvgUnit(fillOpacity * opacity)
                        if (alpha > 0.0) {
                            SvgRasterizer(bitmap, samplesPerPixel: samplesPerPixel).fill(
                                path,
                                matrix: matrix,
                                color: color,
                                fillRule: SvgFillRule.Nonzero,
                                opacity: alpha
                            )
                        }
                    case None => ()
                }
            }
        case _ => ()
    }
}

private func applyClipReference(
    bitmap: SvgBitmap,
    id: String,
    matrix: SvgMatrix,
    box: SvgBounds,
    samplesPerPixel: Int64,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): Unit {
    if (depth >= 64) {
        if (containsSvgStackId(stack, id)) {
            warnings.add("clipPath 循环引用在深度 64 终止「${id}」")
            return
        }
        throw SvgException("clipPath 引用深度超过 64", kind: SvgErrorKind.Limit)
    }
    let target = findSvgElementById(root, id)
    let clip = match (target) {
        case Some(value) => value
        case None =>
            warnings.add("clipPath 引用目标「${id}」不存在")
            return
    }
    let units = SvgCoordinateUnits.fromName(
        (clip.attr("clipPathUnits") ?? "userSpaceOnUse").trimAscii()
    ) ?? SvgCoordinateUnits.UserSpaceOnUse
    let nextStack = appendSvgStackId(stack, id)
    let mask = renderClipCoverage(
        clip,
        bitmap.width,
        bitmap.height,
        samplesPerPixel,
        matrix,
        units,
        box,
        root,
        warnings,
        nextStack,
        depth + 1,
        styles,
        viewportWidth,
        viewportHeight
    )
    mask.applyTo(bitmap)
}

private func applyMaskReference(
    bitmap: SvgBitmap,
    id: String,
    matrix: SvgMatrix,
    box: SvgBounds,
    samplesPerPixel: Int64,
    root: ?SvgElement,
    warnings: ArrayList<String>,
    stack: Array<String>,
    depth: Int64,
    styles: ?SvgComputedStyleTree,
    viewportWidth: Float64,
    viewportHeight: Float64
): Unit {
    if (depth >= 64) {
        if (containsSvgStackId(stack, id)) {
            warnings.add("mask 循环引用在深度 64 终止「${id}」")
            return
        }
        throw SvgException("mask 引用深度超过 64", kind: SvgErrorKind.Limit)
    }
    let target = findSvgElementById(root, id)
    let maskElement = match (target) {
        case Some(value) => value
        case None =>
            warnings.add("mask 引用目标「${id}」不存在")
            return
    }
    let maskUnits = SvgCoordinateUnits.fromName(
        (maskElement.attr("maskUnits") ?? "objectBoundingBox").trimAscii()
    ) ?? SvgCoordinateUnits.ObjectBoundingBox
    let contentUnits = SvgCoordinateUnits.fromName(
        (maskElement.attr("maskContentUnits") ?? "userSpaceOnUse").trimAscii()
    ) ?? SvgCoordinateUnits.UserSpaceOnUse
    let nextStack = appendSvgStackId(stack, id)
    let mask = renderMaskCoverage(
        maskElement,
        bitmap.width,
        bitmap.height,
        samplesPerPixel,
        matrix,
        maskUnits,
        contentUnits,
        box,
        root,
        warnings,
        nextStack,
        depth + 1,
        styles,
        viewportWidth,
        viewportHeight
    )
    mask.applyTo(bitmap)
}

private func readEffectId(raw: ?String): ?String {
    match (raw) {
        case Some(text) =>
            let trimmed = text.trimAscii()
            if (trimmed.size < 4 || trimmed[0..4].toAsciiLower() != "url(") {
                return None
            }
            let close = indexOfSvgByte(trimmed, b')')
            if (close < 0) {
                return None
            }
            var inner = trimAsciiQuotes(trimmed[4..close].trimAscii())
            if (inner.size > 0 && inner[0] == b'#') {
                return Some(inner[1..])
            }
            None
        case None => None
    }
}

private func rootOfSvgElement(element: SvgElement): SvgElement {
    var current = element
    while (true) {
        match (current.parent) {
            case Some(parent) => current = parent
            case None => return current
        }
    }
    current
}

private func appendSvgStackId(stack: Array<String>, id: String): Array<String> {
    let result = ArrayList<String>()
    for (value in stack) {
        result.add(value)
    }
    result.add(id)
    result.toArray()
}

private func containsSvgStackId(stack: Array<String>, id: String): Bool {
    for (value in stack) {
        if (value == id) {
            return true
        }
    }
    false
}

internal func elementPathData(
    element: SvgElement,
    style!: ?SvgComputedStyle = None
): ?SvgPathData {
    match (element) {
        case rect: SvgRect =>
            let width = lengthOrZero(svgStyledLength(style, "width", rect.width))
            let height = lengthOrZero(svgStyledLength(style, "height", rect.height))
            let x = lengthOrZero(svgStyledLength(style, "x", rect.x))
            let y = lengthOrZero(svgStyledLength(style, "y", rect.y))
            return Some(
                SvgPathData([
                    SvgPathCommand(SvgPathCommandKind.MoveTo, false, [x, y]),
                    SvgPathCommand(SvgPathCommandKind.LineTo, false, [x + width, y]),
                    SvgPathCommand(SvgPathCommandKind.LineTo, false, [x + width, y + height]),
                    SvgPathCommand(SvgPathCommandKind.LineTo, false, [x, y + height]),
                    SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
                ])
            )
        case circle: SvgCircle =>
            let radius = lengthOrZero(svgStyledLength(style, "r", circle.r))
            if (radius <= 0.0) {
                return None
            }
            return Some(pointsToPath(circlePolygonForStroke(
                lengthOrZero(svgStyledLength(style, "cx", circle.cx)),
                lengthOrZero(svgStyledLength(style, "cy", circle.cy)),
                radius,
                0.25
            )))
        case ellipse: SvgEllipse =>
            let rx = lengthOrZero(svgStyledLength(style, "rx", ellipse.rx))
            let ry = lengthOrZero(svgStyledLength(style, "ry", ellipse.ry))
            if (rx <= 0.0 || ry <= 0.0) {
                return None
            }
            return Some(
                pointsToPath(ellipsePolygonForClip(
                    lengthOrZero(svgStyledLength(style, "cx", ellipse.cx)),
                    lengthOrZero(svgStyledLength(style, "cy", ellipse.cy)),
                    rx,
                    ry
                ))
            )
        case polygon: SvgPolygon =>
            match (polygon.points) {
                case Some(list) => return Some(pointsToPath(list.points))
                case None => return None
            }
        case polyline: SvgPolyline =>
            match (polyline.points) {
                case Some(list) => return Some(pointsToPath(list.points))
                case None => return None
            }
        case path: SvgPath => return path.d
        case line: SvgLine =>
            return Some(
                SvgPathData([
                    SvgPathCommand(
                        SvgPathCommandKind.MoveTo,
                        false,
                        [lengthOrZero(line.x1), lengthOrZero(line.y1)]
                    ),
                    SvgPathCommand(
                        SvgPathCommandKind.LineTo,
                        false,
                        [lengthOrZero(line.x2), lengthOrZero(line.y2)]
                    )
                ])
            )
        case _ => ()
    }
    None
}

private func ellipsePolygonForClip(cx: Float64, cy: Float64, rx: Float64, ry: Float64): Array<SvgPoint> {
    let radius = if (rx > ry) { rx } else { ry }
    let circle = circlePolygonForStroke(0.0, 0.0, radius, 0.25)
    let points = ArrayList<SvgPoint>()
    for (point in circle) {
        points.add(SvgPoint(cx + point.x / radius * rx, cy + point.y / radius * ry))
    }
    points.toArray()
}

private func pointsToPath(points: Array<SvgPoint>): SvgPathData {
    let commands = ArrayList<SvgPathCommand>()
    if (points.size == 0) {
        return SvgPathData(commands.toArray())
    }
    commands.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [points[0].x, points[0].y]))
    for (index in 1..points.size) {
        commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [points[index].x, points[index].y]))
    }
    commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
    SvgPathData(commands.toArray())
}

private class SvgMaskRegion {
    let x: Int64
    let y: Int64
    let width: Int64
    let height: Int64

    init(x: Int64, y: Int64, width: Int64, height: Int64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }
}

private func maskRegion(
    mask: SvgElement,
    canvasWidth: Int64,
    canvasHeight: Int64,
    contentMatrix: SvgMatrix,
    units: SvgCoordinateUnits,
    box: SvgBounds
): SvgMaskRegion {
    var x = 0.0
    var y = 0.0
    var width = Float64(canvasWidth)
    var height = Float64(canvasHeight)
    if (units == SvgCoordinateUnits.ObjectBoundingBox) {
        x = box.x - box.width * 0.1
        y = box.y - box.height * 0.1
        width = box.width * 1.2
        height = box.height * 1.2
        x = objectBoxValue(mask.attr("x"), box.x, box.width, x, true)
        y = objectBoxValue(mask.attr("y"), box.y, box.height, y, true)
        width = objectBoxValue(mask.attr("width"), box.x, box.width, width, false)
        height = objectBoxValue(mask.attr("height"), box.y, box.height, height, false)
    } else {
        x = userSpaceValue(mask.attr("x"), 0.0)
        y = userSpaceValue(mask.attr("y"), 0.0)
        width = userSpaceValue(mask.attr("width"), Float64(canvasWidth))
        height = userSpaceValue(mask.attr("height"), Float64(canvasHeight))
    }
    let p0 = contentMatrix.apply(SvgPoint(x, y))
    let p1 = contentMatrix.apply(SvgPoint(x + width, y + height))
    let left = if (p0.x < p1.x) { p0.x } else { p1.x }
    let top = if (p0.y < p1.y) { p0.y } else { p1.y }
    let right = if (p0.x > p1.x) { p0.x } else { p1.x }
    let bottom = if (p0.y > p1.y) { p0.y } else { p1.y }
    let firstX = maxI64(0, Int64(floor(left)))
    let firstY = maxI64(0, Int64(floor(top)))
    let lastX = minI64(canvasWidth, Int64(ceil(right)))
    let lastY = minI64(canvasHeight, Int64(ceil(bottom)))
    SvgMaskRegion(firstX, firstY, maxI64(0, lastX - firstX), maxI64(0, lastY - firstY))
}

private func objectBoxValue(
    raw: ?String,
    origin: Float64,
    extent: Float64,
    fallback: Float64,
    isOrigin: Bool
): Float64 {
    match (raw) {
        case Some(text) =>
            match (SvgLength.tryParse(text)) {
                case Some(length) =>
                    let fraction = if (length.unit == SvgLengthUnit.Percent) {
                        length.value / 100.0
                    } else {
                        length.value
                    }
                    if (isOrigin) {
                        origin + fraction * extent
                    } else {
                        fraction * extent
                    }
                case None => fallback
            }
        case None => fallback
    }
}

private func userSpaceValue(raw: ?String, fallback: Float64): Float64 {
    match (raw) {
        case Some(text) =>
            match (SvgLength.tryParse(text)) {
                case Some(length) => length.value
                case None => fallback
            }
        case None => fallback
    }
}

private func maxI64(first: Int64, second: Int64): Int64 {
    if (first > second) { first } else { second }
}

private func minI64(first: Int64, second: Int64): Int64 {
    if (first < second) { first } else { second }
}
