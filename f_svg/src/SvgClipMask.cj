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
        targetBox!: SvgBounds = SvgBounds.empty()
    ): SvgCoverageMask {
        let bitmap = SvgBitmap(width, height)
        let raster = SvgRasterizer(bitmap, samplesPerPixel: samplesPerPixel)
        var matrix = contentMatrix
        if (units == SvgCoordinateUnits.ObjectBoundingBox) {
            matrix = matrix.multiply(bboxMatrix(targetBox))
        }
        let fillRule = SvgFillRule.fromName((clip.attr("clip-rule") ?? "nonzero").trimAscii().toAsciiLower()) ??
            SvgFillRule.Nonzero
        renderClipChildren(clip, matrix, raster, fillRule)
        let coverage = Array<Byte>(width * height, repeat: 0)
        for (index in 0..coverage.size) {
            coverage[index] = bitmap.pixels[index * 4 + 3]
        }
        SvgCoverageMask(width, height, coverage)
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
        targetBox!: SvgBounds = SvgBounds.empty()
    ): SvgCoverageMask {
        let bitmap = SvgBitmap(width, height)
        let raster = SvgRasterizer(bitmap, samplesPerPixel: samplesPerPixel)
        var content = contentMatrix
        if (maskContentUnits == SvgCoordinateUnits.ObjectBoundingBox) {
            content = content.multiply(bboxMatrix(targetBox))
        }
        renderMaskChildren(mask, content, raster)
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
                if (color.alpha > 0.0) {
                    destination.blend(x, y, SvgRgba.fromColor(color, effective))
                }
            }
        }
    }
}

private func bboxMatrix(box: SvgBounds): SvgMatrix {
    SvgMatrix.translate(box.x, box.y).multiply(SvgMatrix.scale(box.width, box.height))
}

private func renderClipChildren(
    element: SvgElement,
    matrix: SvgMatrix,
    raster: SvgRasterizer,
    fillRule: SvgFillRule
): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                let childMatrix = matrix.multiply(elementTransformMatrix(child))
                match (elementPathData(child)) {
                    case Some(data) =>
                        let rule = SvgFillRule.fromName(
                            (child.attr("clip-rule") ?? fillRule.attrName()).trimAscii().toAsciiLower()
                        ) ?? fillRule
                        raster.fill(data, matrix: childMatrix, color: SvgColor.Black, fillRule: rule)
                    case None => renderClipChildren(child, childMatrix, raster, fillRule)
                }
            case _ => ()
        }
    }
}

private func renderMaskChildren(element: SvgElement, matrix: SvgMatrix, raster: SvgRasterizer): Unit {
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                let childMatrix = matrix.multiply(elementTransformMatrix(child))
                match (elementPathData(child)) {
                    case Some(data) =>
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
                                                raster.fill(
                                                    data,
                                                    matrix: childMatrix,
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
                    case None => renderMaskChildren(child, childMatrix, raster)
                }
            case _ => ()
        }
    }
}

private func elementTransformMatrix(element: SvgElement): SvgMatrix {
    match (element.transform) {
        case Some(transform) => transform.toMatrix()
        case None => SvgMatrix.identity
    }
}

private func elementPathData(element: SvgElement): ?SvgPathData {
    match (element) {
        case rect: SvgRect =>
            let width = lengthOrZero(rect.width)
            let height = lengthOrZero(rect.height)
            let x = lengthOrZero(rect.x)
            let y = lengthOrZero(rect.y)
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
            let radius = lengthOrZero(circle.r)
            if (radius <= 0.0) {
                return None
            }
            return Some(pointsToPath(circlePolygonForStroke(lengthOrZero(circle.cx), lengthOrZero(circle.cy), radius, 0.25)))
        case ellipse: SvgEllipse =>
            let rx = lengthOrZero(ellipse.rx)
            let ry = lengthOrZero(ellipse.ry)
            if (rx <= 0.0 || ry <= 0.0) {
                return None
            }
            return Some(
                pointsToPath(ellipsePolygonForClip(lengthOrZero(ellipse.cx), lengthOrZero(ellipse.cy), rx, ry))
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
        x = userSpaceValue(mask.attr("x"), 0.0, contentMatrix)
        y = userSpaceValue(mask.attr("y"), 0.0, contentMatrix)
        width = userSpaceValue(mask.attr("width"), Float64(canvasWidth), contentMatrix)
        height = userSpaceValue(mask.attr("height"), Float64(canvasHeight), contentMatrix)
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

private func userSpaceValue(raw: ?String, fallback: Float64, matrix: SvgMatrix): Float64 {
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
