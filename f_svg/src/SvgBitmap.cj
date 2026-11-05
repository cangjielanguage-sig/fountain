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

import std.io.OutputStream
import std.fs.{FSException, File, Path}
import std.math.*

/** 预乘 RGBA 颜色，内部合成统一使用。 */
public struct SvgRgba <: ToString {
    public let red: Float64
    public let green: Float64
    public let blue: Float64
    public let alpha: Float64

    public init(red: Float64, green: Float64, blue: Float64, alpha: Float64) {
        this.red = red
        this.green = green
        this.blue = blue
        this.alpha = alpha
    }

    public static let transparent = SvgRgba(0.0, 0.0, 0.0, 0.0)

    /** 把非预乘颜色按 `alpha` 转成预乘表示。 */
    public static func fromColor(color: SvgColor, alpha: Float64): SvgRgba {
        let effective = clampSvgUnit(color.alpha * alpha)
        SvgRgba(
            Float64(color.red) / 255.0 * effective,
            Float64(color.green) / 255.0 * effective,
            Float64(color.blue) / 255.0 * effective,
            effective
        )
    }

    /** `this` over `that`：`src + dst × (1 - src.a)`。 */
    public func over(that: SvgRgba): SvgRgba {
        let factor = 1.0 - this.alpha
        SvgRgba(
            this.red + that.red * factor,
            this.green + that.green * factor,
            this.blue + that.blue * factor,
            this.alpha + that.alpha * factor
        )
    }

    /** 反预乘并量化成 8 位 RGBA。 */
    public func toColor(): SvgColor {
        if (this.alpha <= 0.0) {
            return SvgColor.Transparent
        }
        let red = clampSvgUnit(this.red / this.alpha)
        let green = clampSvgUnit(this.green / this.alpha)
        let blue = clampSvgUnit(this.blue / this.alpha)
        SvgColor(
            quantizeSvgChannel(red),
            quantizeSvgChannel(green),
            quantizeSvgChannel(blue),
            alpha: clampSvgUnit(this.alpha)
        )
    }

    public func toString(): String {
        "rgba(${formatSvgNumber(this.red)},${formatSvgNumber(this.green)},${formatSvgNumber(this.blue)},${formatSvgNumber(this.alpha)})"
    }
}

internal func quantizeSvgChannel(value: Float64): UInt8 {
    UInt8(Int64(round(clampSvgUnit(value) * 255.0)))
}

/**
 * RGBA8 位图：行优先、非预乘，`pixels.size == width × height × 4`。
 */
public class SvgBitmap <: ToString {
    public let width: Int64
    public let height: Int64
    public let pixels: Array<Byte>

    public init(width: Int64, height: Int64) {
        if (width <= 0 || height <= 0) {
            throw invalidValue("位图尺寸必须为正，实际 ${width}×${height}")
        }
        if (width > 0x7FFFFFFF || height > 0x7FFFFFFF ||
            width > 2305843009213693951 / height) {
            throw SvgException("位图像素数超出可分配上限", kind: SvgErrorKind.Limit)
        }
        this.width = width
        this.height = height
        this.pixels = Array<Byte>(width * height * 4, repeat: 0)
    }

    public func pixel(x: Int64, y: Int64): SvgColor {
        this.validateCoordinate(x, y)
        let index = (y * this.width + x) * 4
        SvgColor(
            UInt8(Int64(this.pixels[index])),
            UInt8(Int64(this.pixels[index + 1])),
            UInt8(Int64(this.pixels[index + 2])),
            alpha: Float64(this.pixels[index + 3]) / 255.0
        )
    }

    public func setPixel(x: Int64, y: Int64, color: SvgColor): Unit {
        this.validateCoordinate(x, y)
        let index = (y * this.width + x) * 4
        this.pixels[index] = UInt8(Int64(color.red))
        this.pixels[index + 1] = UInt8(Int64(color.green))
        this.pixels[index + 2] = UInt8(Int64(color.blue))
        this.pixels[index + 3] = quantizeSvgChannel(color.alpha)
    }

    /** 用不透明 / 半透明颜色填满画布（直接覆盖）。 */
    public func fill(color: SvgColor): Unit {
        let red = color.red
        let green = color.green
        let blue = color.blue
        let alpha = quantizeSvgChannel(color.alpha)
        var index = 0
        while (index < this.pixels.size) {
            this.pixels[index] = UInt8(Int64(red))
            this.pixels[index + 1] = UInt8(Int64(green))
            this.pixels[index + 2] = UInt8(Int64(blue))
            this.pixels[index + 3] = alpha
            index += 4
        }
    }

    /** 预乘 `over` 合成一个像素。 */
    public func blend(x: Int64, y: Int64, source: SvgRgba): Unit {
        this.validateCoordinate(x, y)
        if (source.alpha <= 0.0) {
            return
        }
        let index = (y * this.width + x) * 4
        let destinationAlpha = Float64(this.pixels[index + 3]) / 255.0
        let destination = SvgRgba(
            Float64(this.pixels[index]) / 255.0 * destinationAlpha,
            Float64(this.pixels[index + 1]) / 255.0 * destinationAlpha,
            Float64(this.pixels[index + 2]) / 255.0 * destinationAlpha,
            destinationAlpha
        )
        let result = source.over(destination).toColor()
        this.pixels[index] = UInt8(Int64(result.red))
        this.pixels[index + 1] = UInt8(Int64(result.green))
        this.pixels[index + 2] = UInt8(Int64(result.blue))
        this.pixels[index + 3] = quantizeSvgChannel(result.alpha)
    }

    /** 输出 PNG 到流。 */
    public func writePng(output: OutputStream): Unit {
        SvgPngEncoder.write(this, output)
    }

    public func toPngBytes(): Array<Byte> {
        SvgPngEncoder.encode(this)
    }

    /** 保存 PNG；目标目录不存在时抛 `InvalidValue`。 */
    public func savePng(path: Path): Unit {
        try {
            File.writeTo(path, this.toPngBytes())
        } catch (_: FSException) {
            throw invalidValue("无法写入 PNG：${path}")
        }
    }

    public func toString(): String {
        "SvgBitmap(${this.width}×${this.height})"
    }

    private func validateCoordinate(x: Int64, y: Int64): Unit {
        if (x < 0 || y < 0 || x >= this.width || y >= this.height) {
            throw invalidValue("像素坐标 (${x}, ${y}) 超出 ${this.width}×${this.height} 位图")
        }
    }
}

/**
 * 渲染选项。
 *
 * `width` / `height` 为 0 表示自动取根元素尺寸；负值非法。
 * `maxPixels` 按像素数计算，超限抛 `Limit`。
 */
public struct SvgRenderOptions {
    public let width: Int64
    public let height: Int64
    public let background: ?SvgColor
    public let samplesPerPixel: Int64
    public let maxPixels: Int64
    public let fonts: ?SvgFontRegistry
    public let devicePixelRatio: Float64
    /** `<image>` 外部资源提供者；`None` 时非 data URI 一律画占位。 */
    public let images: ?SvgImageResourceProvider
    /** 抗锯齿档位；默认超采样，保持 M2 输出。 */
    public let antiAlias: SvgAntiAliasMode

    public init(
        width!: Int64 = 0,
        height!: Int64 = 0,
        background!: ?SvgColor = None,
        samplesPerPixel!: Int64 = 4,
        maxPixels!: Int64 = 64 * 1024 * 1024,
        fonts!: ?SvgFontRegistry = None,
        devicePixelRatio!: Float64 = 1.0,
        images!: ?SvgImageResourceProvider = None,
        antiAlias!: SvgAntiAliasMode = SvgAntiAliasMode.Supersample
    ) {
        if (width < 0 || height < 0) {
            throw invalidValue("渲染宽高不能为负，实际 ${width}×${height}")
        }
        if (samplesPerPixel != 1 && samplesPerPixel != 2 && samplesPerPixel != 4) {
            throw invalidValue("samplesPerPixel 只允许 1 / 2 / 4，实际 ${samplesPerPixel}")
        }
        if (maxPixels <= 0) {
            throw invalidValue("maxPixels 必须为正")
        }
        if (!isFiniteSvgNumber(devicePixelRatio) || devicePixelRatio <= 0.0) {
            throw invalidValue("devicePixelRatio 必须为正的有限数")
        }
        this.width = width
        this.height = height
        this.background = background
        this.samplesPerPixel = samplesPerPixel
        this.maxPixels = maxPixels
        this.fonts = fonts
        this.devicePixelRatio = devicePixelRatio
        this.images = images
        this.antiAlias = antiAlias
    }

    /** 校验输出像素总数；超限抛 `Limit`。 */
    public func validatePixels(width: Int64, height: Int64): Unit {
        if (width < 0 || height < 0) {
            throw invalidValue("输出宽高不能为负")
        }
        if (width == 0 || height == 0) {
            return
        }
        if (width > this.maxPixels / height) {
            throw SvgException("输出像素数超过 maxPixels 上限 ${this.maxPixels}", kind: SvgErrorKind.Limit)
        }
    }
}
