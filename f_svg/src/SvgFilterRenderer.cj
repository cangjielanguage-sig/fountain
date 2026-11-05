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

    public init(registry!: ?SvgFontRegistry = None) {
        this.registry = registry
    }

    /** 计算设备空间滤镜区域并裁剪到画布。 */
    public func region(
        filter: SvgFilter,
        objectBounds: SvgBounds,
        transform: SvgMatrix,
        source: SvgBitmap,
        options: SvgRenderOptions
    ): SvgBounds {
        let objectUnits = filter.filterUnits == SvgCoordinateUnits.ObjectBoundingBox
        let x = filter.x ?? SvgLength(-10.0, unit: SvgLengthUnit.Percent)
        let y = filter.y ?? SvgLength(-10.0, unit: SvgLengthUnit.Percent)
        let width = filter.width ?? SvgLength(120.0, unit: SvgLengthUnit.Percent)
        let height = filter.height ?? SvgLength(120.0, unit: SvgLengthUnit.Percent)
        let localX = filterAxis(x, objectBounds.x, objectBounds.width, objectUnits)
        let localY = filterAxis(y, objectBounds.y, objectBounds.height, objectUnits)
        let localWidth = filterAxis(width, 0.0, objectBounds.width, objectUnits)
        let localHeight = filterAxis(height, 0.0, objectBounds.height, objectUnits)
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
        let area = this.region(filter, objectBounds, transform, source, options)
        let left = Int64(floor(area.x))
        let top = Int64(floor(area.y))
        let right = Int64(ceil(area.x + area.width))
        let bottom = Int64(ceil(area.y + area.height))
        let width = right - left
        let height = bottom - top
        let output = SvgBitmap(source.width, source.height)
        if (width <= 0 || height <= 0) {
            return output
        }
        if (width > options.maxPixels / height) {
            throw SvgException(
                "滤镜区域像素数超过 maxPixels 上限 ${options.maxPixels}",
                kind: SvgErrorKind.Limit
            )
        }
        let sourceBuffer = SvgFilterBuffer.fromBitmap(source, left, top, width, height)
        let linear = (filter.attr("color-interpolation-filters") ?? "srgb").trimAscii().toAsciiLower() ==
            "linearrgb"
        let working = if (linear) {
            toLinearRgb(sourceBuffer)
        } else {
            sourceBuffer
        }
        let result = this.runChain(filter, working)
        let final = if (linear) {
            toSrgb(result)
        } else {
            result
        }
        final.writeTo(output, left, top)
        output
    }

    private func runChain(filter: SvgFilter, source: SvgFilterBuffer): SvgFilterBuffer {
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
            let result = applyFilterPrimitive(primitive, input, input2)
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
    objectUnits: Bool
): Float64 {
    if (objectUnits) {
        let fraction = if (length.unit == SvgLengthUnit.Percent) {
            length.value / 100.0
        } else {
            length.value
        }
        base + fraction * extent
    } else {
        length.value
    }
}

private func primitiveSecondInput(primitive: SvgFilterPrimitive): ?String {
    match (primitive) {
        case blend: SvgFeBlend => blend.in2
        case composite: SvgFeComposite => composite.in2
        case _ => None
    }
}

private func transparentBuffer(width: Int64, height: Int64): SvgFilterBuffer {
    SvgFilterBuffer(width, height)
}

/** 原语分派；M3 阶段 9 前默认直通输入。 */
private func applyFilterPrimitive(
    primitive: SvgFilterPrimitive,
    input: SvgFilterBuffer,
    input2: SvgFilterBuffer
): SvgFilterBuffer {
    input.copy()
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
