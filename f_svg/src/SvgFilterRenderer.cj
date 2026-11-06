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

/**
 * 滤镜链执行器。
 *
 * 区域按 `filterUnits` 换算并裁剪到画布；缓冲为区域尺寸，结果写回同尺寸画布，
 * 区域外透明。每次原语产生新缓冲，引用缺失时输出透明并记 warning。
 */
public class SvgFilterRenderer {
    public let warnings = ArrayList<String>()
    private let registry: ?SvgFontRegistry
    private var images: ?SvgImageResource = None

    public init(registry!: ?SvgFontRegistry = None) {
        this.registry = registry
    }

    /** 绑定本次渲染共享的图像解码资源（与 `<image>` 共用预算）。 */
    internal func attachImages(value: SvgImageResource): Unit {
        this.images = Some(value)
    }

    /** 计算设备空间滤镜区域并裁剪到画布。 */
    public func region(
        filter: SvgFilter,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        source: SvgBitmap
    ): SvgBounds {
        let objectUnits = filter.filterUnits == SvgCoordinateUnits.ObjectBoundingBox
        let x = filter.x ?? SvgLength(-10.0, unit: SvgLengthUnit.Percent)
        let y = filter.y ?? SvgLength(-10.0, unit: SvgLengthUnit.Percent)
        let width = filter.width ?? SvgLength(120.0, unit: SvgLengthUnit.Percent)
        let height = filter.height ?? SvgLength(120.0, unit: SvgLengthUnit.Percent)
        // userSpaceOnUse 的百分比以当前视口的用户空间尺寸为基准，
        // 不能直接用设备像素尺寸，否则 viewBox / dpr 缩放会二次放大。
        let inverse = match (transform.invert()) {
            case Some(value) => value
            case None => SvgMatrix.identity
        }
        let userOrigin = inverse.apply(SvgPoint(0.0, 0.0))
        let userCornerX = inverse.apply(SvgPoint(Float64(source.width), 0.0))
        let userCornerY = inverse.apply(SvgPoint(0.0, Float64(source.height)))
        let viewportWidth = sqrt(
            (userCornerX.x - userOrigin.x) * (userCornerX.x - userOrigin.x) +
            (userCornerX.y - userOrigin.y) * (userCornerX.y - userOrigin.y)
        )
        let viewportHeight = sqrt(
            (userCornerY.x - userOrigin.x) * (userCornerY.x - userOrigin.x) +
            (userCornerY.y - userOrigin.y) * (userCornerY.y - userOrigin.y)
        )
        let localX = filterAxis(x, objectBounds.x, objectBounds.width, objectUnits, viewportWidth)
        let localY = filterAxis(y, objectBounds.y, objectBounds.height, objectUnits, viewportHeight)
        let localWidth = filterAxis(width, 0.0, objectBounds.width, objectUnits, viewportWidth)
        let localHeight = filterAxis(height, 0.0, objectBounds.height, objectUnits, viewportHeight)
        let c0 = transform.apply(SvgPoint(localX, localY))
        let c1 = transform.apply(SvgPoint(localX + localWidth, localY))
        let c2 = transform.apply(SvgPoint(localX + localWidth, localY + localHeight))
        let c3 = transform.apply(SvgPoint(localX, localY + localHeight))
        let minimumX = max(0.0, min(min(c0.x, c1.x), min(c2.x, c3.x)))
        let maximumX = min(Float64(source.width), max(max(c0.x, c1.x), max(c2.x, c3.x)))
        let minimumY = max(0.0, min(min(c0.y, c1.y), min(c2.y, c3.y)))
        let maximumY = min(Float64(source.height), max(max(c0.y, c1.y), max(c2.y, c3.y)))
        if (maximumX <= minimumX || maximumY <= minimumY) {
            return SvgBounds(minimumX, minimumY, 0.0, 0.0)
        }
        SvgBounds(minimumX, minimumY, maximumX - minimumX, maximumY - minimumY)
    }

    /** 执行滤镜链，返回与 `source` 同尺寸、区域外透明的位图。 */
    public func apply(
        filter: SvgFilter,
        source: SvgBitmap,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        options: SvgRenderOptions
    ): SvgBitmap {
        if (filter.primitives.size == 0) {
            let output = SvgBitmap(source.width, source.height)
            for (index in 0..source.pixels.size) {
                output.pixels[index] = source.pixels[index]
            }
            return output
        }
        let area = this.region(filter, objectBounds, transform, source)
        let left = Int64(floor(area.x))
        let top = Int64(floor(area.y))
        let right = Int64(ceil(area.x + area.width))
        let bottom = Int64(ceil(area.y + area.height))
        let width = right - left
        let height = bottom - top
        if (width <= 0 || height <= 0) {
            this.warnings.add(
                "滤镜区域尺寸 ${width}×${height} 为零，输出透明（元素「${filter.tag}」）"
            )
            return SvgBitmap(source.width, source.height)
        }
        // 先做除法判定再分配区域缓冲与输出位图，保证超限时不发生大块分配。
        if (width > options.maxPixels / height) {
            throw SvgException(
                "滤镜区域像素数超过 maxPixels 上限 ${options.maxPixels}",
                kind: SvgErrorKind.Limit
            )
        }
        let output = SvgBitmap(source.width, source.height)
        let sourceBuffer = SvgFilterBuffer.fromBitmap(source, left, top, width, height)
        let linear = (filter.attr("color-interpolation-filters") ?? "srgb").trimAscii().toAsciiLower() ==
            "linearrgb"
        let working = if (linear) {
            toLinearRgb(sourceBuffer)
        } else {
            sourceBuffer
        }
        let primitiveObjectUnits = filter.primitiveUnits == SvgCoordinateUnits.ObjectBoundingBox
        // 原语坐标与滤镜区域一样是用户空间量：objectBoundingBox 先乘包围盒尺寸，
        // 再统一乘元素 / 视口 CTM 的缩放分量，换算到设备像素缓冲。
        let ctmScaleX = sqrt(transform.a * transform.a + transform.b * transform.b)
        let ctmScaleY = sqrt(transform.c * transform.c + transform.d * transform.d)
        let primitiveScaleX = (if (primitiveObjectUnits) { objectBounds.width } else { 1.0 }) *
            ctmScaleX
        let primitiveScaleY = (if (primitiveObjectUnits) { objectBounds.height } else { 1.0 }) *
            ctmScaleY
        let result = this.runChain(filter, working, primitiveScaleX, primitiveScaleY)
        let final = if (linear) {
            toSrgb(result)
        } else {
            result
        }
        final.writeTo(output, left, top)
        output
    }

    private func mergePrimitive(
        merge: SvgFeMerge,
        fallback: SvgFilterBuffer,
        named: HashMap<String, SvgFilterBuffer>
    ): SvgFilterBuffer {
        let buffers = ArrayList<SvgFilterBuffer>()
        for (node in merge.children) {
            match (node) {
                case ElementNode(element) =>
                    match (element) {
                        case mergeNode: SvgFeMergeNode =>
                            let buffer = match (mergeNode.inSource) {
                                case Some(name) =>
                                    match (named.get(name)) {
                                        case Some(value) => value
                                        case None =>
                                            this.warnings.add(
                                                "feMergeNode 引用了不存在的输入「${name}」"
                                            )
                                            transparentBuffer(fallback.width, fallback.height)
                                    }
                                case None => fallback
                            }
                            buffers.add(buffer)
                        case _ => ()
                    }
                case _ => ()
            }
        }
        if (buffers.size == 0) {
            return fallback.copy()
        }
        mergeFilterBuffers(buffers)
    }

    private func runChain(
        filter: SvgFilter,
        source: SvgFilterBuffer,
        primitiveScaleX: Float64,
        primitiveScaleY: Float64
    ): SvgFilterBuffer {
        let named = HashMap<String, SvgFilterBuffer>()
        named["SourceGraphic"] = source
        var previous = source
        var index: Int64 = 0
        while (index < filter.primitives.size) {
            let primitive = filter.primitives[index]
            let input = match (primitive.inSource) {
                case Some(name) =>
                    match (named.get(name)) {
                        case Some(value) => value
                        case None =>
                            this.warnings.add(
                                "滤镜原语「${primitive.tag}」引用了不存在的输入「${name}」"
                            )
                            transparentBuffer(source.width, source.height)
                    }
                case None => previous
            }
            var input2 = source
            let secondName = primitiveSecondInput(primitive)
            match (secondName) {
                case Some(name) =>
                    input2 = match (named.get(name)) {
                        case Some(value) => value
                        case None =>
                            this.warnings.add(
                                "滤镜原语「${primitive.tag}」引用了不存在的输入「${name}」"
                            )
                            transparentBuffer(source.width, source.height)
                    }
                case None => ()
            }
            let result = match (primitive) {
                case merge: SvgFeMerge => this.mergePrimitive(merge, input, named)
                case _ => applyFilterPrimitive(
                    primitive,
                    input,
                    input2,
                    this.warnings,
                    primitiveScaleX,
                    primitiveScaleY,
                    this.images
                )
            }
            let name = primitive.result ?? "result${index}"
            named[name] = result
            previous = result
            index++
        }
        previous
    }
}

private func filterAxis(
    length: SvgLength,
    base: Float64,
    extent: Float64,
    objectUnits: Bool,
    viewportExtent: Float64
): Float64 {
    if (objectUnits) {
        let fraction = if (length.unit == SvgLengthUnit.Percent) {
            length.value / 100.0
        } else {
            length.value
        }
        base + fraction * extent
    } else if (length.unit == SvgLengthUnit.Percent) {
        length.value / 100.0 * viewportExtent
    } else {
        length.value
    }
}

private func primitiveSecondInput(primitive: SvgFilterPrimitive): ?String {
    match (primitive) {
        case blend: SvgFeBlend => blend.in2
        case composite: SvgFeComposite => composite.in2
        case displacement: SvgFeDisplacementMap => displacement.in2
        case _ => None
    }
}

private func transparentBuffer(width: Int64, height: Int64): SvgFilterBuffer {
    SvgFilterBuffer(width, height)
}

/** 原语分派。 */
private func applyFilterPrimitive(
    primitive: SvgFilterPrimitive,
    input: SvgFilterBuffer,
    input2: SvgFilterBuffer,
    warnings: ArrayList<String>,
    scaleX: Float64,
    scaleY: Float64,
    images: ?SvgImageResource
): SvgFilterBuffer {
    match (primitive) {
        case blur: SvgFeGaussianBlur =>
            let deviations = blur.stdDeviation.values
            var sigmaX = 0.0
            var sigmaY = 0.0
            if (deviations.size == 1) {
                sigmaX = deviations[0] * scaleX
                sigmaY = deviations[0] * scaleY
            } else if (deviations.size >= 2) {
                sigmaX = deviations[0] * scaleX
                sigmaY = deviations[1] * scaleY
            }
            if (sigmaX < 0.0 || sigmaY < 0.0) {
                warnings.add("feGaussianBlur 的 stdDeviation 含负值，按 0 处理")
                sigmaX = max(0.0, sigmaX)
                sigmaY = max(0.0, sigmaY)
            }
            blurFilterBuffer(input, sigmaX, sigmaY)
        case offset: SvgFeOffset =>
            offsetFilterBuffer(
                input,
                Int64(round(offset.dx.value * scaleX)),
                Int64(round(offset.dy.value * scaleY))
            )
        case flood: SvgFeFlood =>
            let color = match (flood.floodColor.color) {
                case Some(value) => value
                case None => SvgColor.Black
            }
            floodFilterBuffer(input.width, input.height, color, flood.floodOpacity)
        case blend: SvgFeBlend =>
            blendFilterBuffer(input, input2, blend.mode)
        case composite: SvgFeComposite =>
            compositeFilterBuffer(
                input,
                input2,
                composite.operatorKind,
                composite.k1,
                composite.k2,
                composite.k3,
                composite.k4
            )
        case matrix: SvgFeColorMatrix =>
            colorMatrixFilterBuffer(input, matrix.matrixType, matrix.values, warnings)
        case tile: SvgFeTile =>
            if (tileContentBounds(input).size == 0) {
                warnings.add("feTile 的输入为空，输出透明")
                transparentBuffer(input.width, input.height)
            } else {
                tileFilterBuffer(input, input.width, input.height)
            }
        case transfer: SvgFeComponentTransfer =>
            componentTransferFilterBuffer(input, transfer, warnings)
        case morphology: SvgFeMorphology =>
            morphologyFilterBuffer(input, morphology, scaleX, scaleY, warnings)
        case convolve: SvgFeConvolveMatrix =>
            convolveFilterBuffer(input, convolve, warnings)
        case turbulence: SvgFeTurbulence =>
            turbulenceFilterBuffer(input, turbulence, scaleX, scaleY, warnings)
        case displacement: SvgFeDisplacementMap =>
            displacementFilterBuffer(input, input2, displacement, scaleX, scaleY, warnings)
        case image: SvgFeImage =>
            feImageFilterBuffer(input, image, images, warnings)
        case diffuse: SvgFeDiffuseLighting =>
            lightingFilterBuffer(input, diffuse, false, scaleX, scaleY, warnings)
        case specular: SvgFeSpecularLighting =>
            lightingFilterBuffer(input, specular, true, scaleX, scaleY, warnings)
        case _ => input.copy()
    }
}

private func toLinearRgb(buffer: SvgFilterBuffer): SvgFilterBuffer {
    let output = SvgFilterBuffer(buffer.width, buffer.height)
    var index = 0
    while (index < buffer.pixels.size) {
        output.pixels[index] = linearChannel(buffer.pixels[index])
        output.pixels[index + 1] = linearChannel(buffer.pixels[index + 1])
        output.pixels[index + 2] = linearChannel(buffer.pixels[index + 2])
        output.pixels[index + 3] = buffer.pixels[index + 3]
        index += 4
    }
    output
}

private func toSrgb(buffer: SvgFilterBuffer): SvgFilterBuffer {
    let output = SvgFilterBuffer(buffer.width, buffer.height)
    var index = 0
    while (index < buffer.pixels.size) {
        output.pixels[index] = srgbChannel(buffer.pixels[index])
        output.pixels[index + 1] = srgbChannel(buffer.pixels[index + 1])
        output.pixels[index + 2] = srgbChannel(buffer.pixels[index + 2])
        output.pixels[index + 3] = buffer.pixels[index + 3]
        index += 4
    }
    output
}

private func linearChannel(value: Byte): Byte {
    let channel = Float64(value) / 255.0
    let linear = if (channel <= 0.04045) {
        channel / 12.92
    } else {
        pow((channel + 0.055) / 1.055, 2.4)
    }
    UInt8(Int64(round(clampSvgUnit(linear) * 255.0)))
}

private func srgbChannel(value: Byte): Byte {
    let channel = Float64(value) / 255.0
    let encoded = if (channel <= 0.0031308) {
        channel * 12.92
    } else {
        1.055 * pow(channel, 1.0 / 2.4) - 0.055
    }
    UInt8(Int64(round(clampSvgUnit(encoded) * 255.0)))
}
