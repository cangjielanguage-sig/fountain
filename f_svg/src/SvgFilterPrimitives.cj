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

/** 可分离高斯模糊；σ=0 的方向直通。核半径 `ceil(3σ)`。 */
internal func blurFilterBuffer(
    input: SvgFilterBuffer,
    sigmaX: Float64,
    sigmaY: Float64
): SvgFilterBuffer {
    if (sigmaX <= 0.0 && sigmaY <= 0.0) {
        return input.copy()
    }
    var current = bytesToFloat(input)
    if (sigmaX > 0.0) {
        current = convolveHorizontal(current, input.width, input.height, gaussianKernel(sigmaX))
    }
    if (sigmaY > 0.0) {
        current = convolveVertical(current, input.width, input.height, gaussianKernel(sigmaY))
    }
    floatsToBuffer(current, input.width, input.height)
}

private func gaussianKernel(sigma: Float64): Array<Float64> {
    let radius = Int64(ceil(3.0 * sigma))
    let size = radius * 2 + 1
    let kernel = Array<Float64>(size, repeat: 0.0)
    var total = 0.0
    var offset = -radius
    while (offset <= radius) {
        let value = exp(-Float64(offset * offset) / (2.0 * sigma * sigma))
        kernel[offset + radius] = value
        total += value
        offset++
    }
    if (total > 0.0) {
        for (index in 0..size) {
            kernel[index] = kernel[index] / total
        }
    }
    kernel
}

private func bytesToFloat(buffer: SvgFilterBuffer): Array<Float64> {
    let values = Array<Float64>(buffer.pixels.size, repeat: 0.0)
    for (index in 0..buffer.pixels.size) {
        values[index] = Float64(buffer.pixels[index])
    }
    values
}

private func floatsToBuffer(values: Array<Float64>, width: Int64, height: Int64): SvgFilterBuffer {
    let buffer = SvgFilterBuffer(width, height)
    for (index in 0..values.size) {
        buffer.pixels[index] = UInt8(Int64(round(clampSvgUnit(values[index] / 255.0) * 255.0)))
    }
    buffer
}

private func convolveHorizontal(
    values: Array<Float64>,
    width: Int64,
    height: Int64,
    kernel: Array<Float64>
): Array<Float64> {
    let output = Array<Float64>(values.size, repeat: 0.0)
    let radius = (kernel.size - 1) / 2
    var y = 0
    while (y < height) {
        var x = 0
        while (x < width) {
            var channel = 0
            while (channel < 4) {
                var sum = 0.0
                var offset = -radius
                while (offset <= radius) {
                    let sourceX = x + offset
                    if (sourceX >= 0 && sourceX < width) {
                        sum += values[(y * width + sourceX) * 4 + channel] * kernel[offset + radius]
                    }
                    offset++
                }
                output[(y * width + x) * 4 + channel] = sum
                channel++
            }
            x++
        }
        y++
    }
    output
}

private func convolveVertical(
    values: Array<Float64>,
    width: Int64,
    height: Int64,
    kernel: Array<Float64>
): Array<Float64> {
    let output = Array<Float64>(values.size, repeat: 0.0)
    let radius = (kernel.size - 1) / 2
    var y = 0
    while (y < height) {
        var x = 0
        while (x < width) {
            var channel = 0
            while (channel < 4) {
                var sum = 0.0
                var offset = -radius
                while (offset <= radius) {
                    let sourceY = y + offset
                    if (sourceY >= 0 && sourceY < height) {
                        sum += values[(sourceY * width + x) * 4 + channel] * kernel[offset + radius]
                    }
                    offset++
                }
                output[(y * width + x) * 4 + channel] = sum
                channel++
            }
            x++
        }
        y++
    }
    output
}

/** 整数平移，越界补透明。 */
internal func offsetFilterBuffer(input: SvgFilterBuffer, dx: Int64, dy: Int64): SvgFilterBuffer {
    let output = SvgFilterBuffer(input.width, input.height)
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            let sourceX = x - dx
            let sourceY = y - dy
            if (sourceX >= 0 && sourceY >= 0 &&
                sourceX < input.width && sourceY < input.height) {
                let sourceBase = (sourceY * input.width + sourceX) * 4
                let targetBase = (y * input.width + x) * 4
                output.pixels[targetBase] = input.pixels[sourceBase]
                output.pixels[targetBase + 1] = input.pixels[sourceBase + 1]
                output.pixels[targetBase + 2] = input.pixels[sourceBase + 2]
                output.pixels[targetBase + 3] = input.pixels[sourceBase + 3]
            }
            x++
        }
        y++
    }
    output
}

/** 颜色 × 不透明度填满缓冲。 */
internal func floodFilterBuffer(
    width: Int64,
    height: Int64,
    color: SvgColor,
    opacity: Float64
): SvgFilterBuffer {
    let buffer = SvgFilterBuffer(width, height)
    let alpha = clampSvgUnit(color.alpha * opacity)
    let quantized = UInt8(Int64(round(alpha * 255.0)))
    var index = 0
    while (index < buffer.pixels.size) {
        buffer.pixels[index] = color.red
        buffer.pixels[index + 1] = color.green
        buffer.pixels[index + 2] = color.blue
        buffer.pixels[index + 3] = quantized
        index += 4
    }
    buffer
}

/** `feBlend`：逐通道可分离混合，alpha 按 over 合成。 */
internal func blendFilterBuffer(
    input: SvgFilterBuffer,
    input2: SvgFilterBuffer,
    mode: SvgBlendMode
): SvgFilterBuffer {
    let output = SvgFilterBuffer(input.width, input.height)
    var index = 0
    while (index < input.pixels.size) {
        let alphaSource = Float64(input.pixels[index + 3]) / 255.0
        let alphaBackdrop = Float64(input2.pixels[index + 3]) / 255.0
        let alphaResult = clampSvgUnit(alphaSource + alphaBackdrop * (1.0 - alphaSource))
        var channel = 0
        while (channel < 3) {
            let source = Float64(input.pixels[index + channel]) / 255.0
            let backdrop = Float64(input2.pixels[index + channel]) / 255.0
            let blended = match (mode) {
                case Normal => source
                case Multiply => backdrop * source
                case Screen => backdrop + source - backdrop * source
                case Darken => min(backdrop, source)
                case Lighten => max(backdrop, source)
            }
            let premultiplied = (1.0 - alphaBackdrop) * alphaSource * source +
                alphaBackdrop * alphaSource * blended +
                (1.0 - alphaSource) * alphaBackdrop * backdrop
            let result = if (alphaResult > 0.0) {
                clampSvgUnit(premultiplied / alphaResult)
            } else {
                0.0
            }
            output.pixels[index + channel] = UInt8(Int64(round(result * 255.0)))
            channel++
        }
        output.pixels[index + 3] = UInt8(Int64(round(alphaResult * 255.0)))
        index += 4
    }
    output
}

/** `feComposite`：Porter-Duff 与 arithmetic。 */
internal func compositeFilterBuffer(
    input: SvgFilterBuffer,
    input2: SvgFilterBuffer,
    operatorKind: SvgCompositeOperator,
    k1: Float64,
    k2: Float64,
    k3: Float64,
    k4: Float64
): SvgFilterBuffer {
    let output = SvgFilterBuffer(input.width, input.height)
    var index = 0
    while (index < input.pixels.size) {
        let alphaSource = Float64(input.pixels[index + 3]) / 255.0
        let alphaBackdrop = Float64(input2.pixels[index + 3]) / 255.0
        if (operatorKind == SvgCompositeOperator.Arithmetic) {
            var channel = 0
            while (channel < 4) {
                let source = Float64(input.pixels[index + channel]) / 255.0
                let backdrop = Float64(input2.pixels[index + channel]) / 255.0
                let result = clampSvgUnit(
                    k1 * source * backdrop + k2 * source + k3 * backdrop + k4
                )
                output.pixels[index + channel] = UInt8(Int64(round(result * 255.0)))
                channel++
            }
        } else {
            let alphaResult = match (operatorKind) {
                case Over => alphaSource + alphaBackdrop * (1.0 - alphaSource)
                case In => alphaSource * alphaBackdrop
                case Out => alphaSource * (1.0 - alphaBackdrop)
                case Atop => alphaBackdrop
                case Xor => alphaSource * (1.0 - alphaBackdrop) +
                    alphaBackdrop * (1.0 - alphaSource)
                case Arithmetic => 0.0
            }
            var channel = 0
            while (channel < 3) {
                let source = Float64(input.pixels[index + channel]) / 255.0 * alphaSource
                let backdrop = Float64(input2.pixels[index + channel]) / 255.0 * alphaBackdrop
                let premultiplied = match (operatorKind) {
                    case Over => source + backdrop * (1.0 - alphaSource)
                    case In => source * alphaBackdrop
                    case Out => source * (1.0 - alphaBackdrop)
                    case Atop => source * alphaBackdrop + backdrop * (1.0 - alphaSource)
                    case Xor => source * (1.0 - alphaBackdrop) +
                        backdrop * (1.0 - alphaSource)
                    case Arithmetic => 0.0
                }
                let result = if (alphaResult > 0.0) {
                    clampSvgUnit(premultiplied / alphaResult)
                } else {
                    0.0
                }
                output.pixels[index + channel] = UInt8(Int64(round(result * 255.0)))
                channel++
            }
            output.pixels[index + 3] = UInt8(Int64(round(clampSvgUnit(alphaResult) * 255.0)))
        }
        index += 4
    }
    output
}

/** 按顺序 over 合并；后面的缓冲在上。 */
internal func mergeFilterBuffers(buffers: ArrayList<SvgFilterBuffer>): SvgFilterBuffer {
    if (buffers.size == 0) {
        throw invalidValue("feMerge 没有任何输入")
    }
    var output = SvgFilterBuffer(buffers[0].width, buffers[0].height)
    for (buffer in buffers) {
        output = compositeFilterBuffer(
            buffer,
            output,
            SvgCompositeOperator.Over,
            0.0,
            0.0,
            0.0,
            0.0
        )
    }
    output
}

/** `feColorMatrix`：四种类型，结果钳制到 0..1。 */
internal func colorMatrixFilterBuffer(
    input: SvgFilterBuffer,
    matrixType: SvgColorMatrixType,
    values: Array<Float64>,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let matrix = colorMatrixFor(matrixType, values, warnings)
    if (matrix.size != 20) {
        return input.copy()
    }
    let output = SvgFilterBuffer(input.width, input.height)
    var index = 0
    while (index < input.pixels.size) {
        let red = Float64(input.pixels[index]) / 255.0
        let green = Float64(input.pixels[index + 1]) / 255.0
        let blue = Float64(input.pixels[index + 2]) / 255.0
        let alpha = Float64(input.pixels[index + 3]) / 255.0
        var channel = 0
        while (channel < 4) {
            let base = channel * 5
            let result = matrix[base] * red + matrix[base + 1] * green +
                matrix[base + 2] * blue + matrix[base + 3] * alpha + matrix[base + 4]
            output.pixels[index + channel] = UInt8(Int64(round(clampSvgUnit(result) * 255.0)))
            channel++
        }
        index += 4
    }
    output
}

private func colorMatrixFor(
    matrixType: SvgColorMatrixType,
    values: Array<Float64>,
    warnings: ArrayList<String>
): Array<Float64> {
    match (matrixType) {
        case Matrix =>
            if (values.size != 20) {
                warnings.add("feColorMatrix type=matrix 需要 20 个值，实际 ${values.size} 个，按直通处理")
                return Array<Float64>()
            }
            for (value in values) {
                if (value.isNaN() || value.isInf()) {
                    warnings.add("feColorMatrix 含非有限值，按直通处理")
                    return Array<Float64>()
                }
            }
            values
        case Saturate =>
            if (values.size != 1) {
                warnings.add("feColorMatrix type=saturate 需要 1 个值，按直通处理")
                return Array<Float64>()
            }
            let s = values[0]
            if (s.isNaN() || s.isInf()) {
                warnings.add("feColorMatrix type=saturate 含非有限值，按直通处理")
                return Array<Float64>()
            }
            [
                0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0.0, 0.0,
                0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0.0, 0.0,
                0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0.0, 0.0,
                0.0, 0.0, 0.0, 1.0, 0.0
            ]
        case HueRotate =>
            if (values.size != 1) {
                warnings.add("feColorMatrix type=hueRotate 需要 1 个值，按直通处理")
                return Array<Float64>()
            }
            if (values[0].isNaN() || values[0].isInf()) {
                warnings.add("feColorMatrix type=hueRotate 含非有限值，按直通处理")
                return Array<Float64>()
            }
            let radians = values[0] * 3.141592653589793 / 180.0
            let cosine = cos(radians)
            let sine = sin(radians)
            [
                0.213 + cosine * 0.787 - sine * 0.213,
                0.715 - cosine * 0.715 - sine * 0.715,
                0.072 - cosine * 0.072 + sine * 0.928,
                0.0, 0.0,
                0.213 - cosine * 0.213 + sine * 0.143,
                0.715 + cosine * 0.285 + sine * 0.140,
                0.072 - cosine * 0.072 - sine * 0.283,
                0.0, 0.0,
                0.213 - cosine * 0.213 - sine * 0.787,
                0.715 - cosine * 0.715 + sine * 0.715,
                0.072 + cosine * 0.928 + sine * 0.072,
                0.0, 0.0,
                0.0, 0.0, 0.0, 1.0, 0.0
            ]
        case LuminanceToAlpha =>
            [
                0.0, 0.0, 0.0, 0.0, 0.0,
                0.0, 0.0, 0.0, 0.0, 0.0,
                0.0, 0.0, 0.0, 0.0, 0.0,
                0.2125, 0.7154, 0.0721, 0.0, 0.0
            ]
    }
}

/** `feTile`：把输入的非透明内容当作 tile 周期平铺到滤镜区域。 */
internal func tileFilterBuffer(
    input: SvgFilterBuffer,
    width: Int64,
    height: Int64
): SvgFilterBuffer {
    let output = SvgFilterBuffer(width, height)
    let content = tileContentBounds(input)
    if (content.size == 0) {
        return output
    }
    let originX = content[0]
    let originY = content[1]
    let tileWidth = content[2]
    let tileHeight = content[3]
    var y = 0
    while (y < height) {
        var x = 0
        while (x < width) {
            let sourceX = originX + positiveMod(x - originX, tileWidth)
            let sourceY = originY + positiveMod(y - originY, tileHeight)
            let sourceBase = (sourceY * input.width + sourceX) * 4
            let targetBase = (y * width + x) * 4
            output.pixels[targetBase] = input.pixels[sourceBase]
            output.pixels[targetBase + 1] = input.pixels[sourceBase + 1]
            output.pixels[targetBase + 2] = input.pixels[sourceBase + 2]
            output.pixels[targetBase + 3] = input.pixels[sourceBase + 3]
            x++
        }
        y++
    }
    output
}

/** 输入缓冲中非透明内容的包围盒 `[x, y, width, height]`；全透明返回空数组。 */
internal func tileContentBounds(input: SvgFilterBuffer): Array<Int64> {
    var minimumX = input.width
    var minimumY = input.height
    var maximumX: Int64 = -1
    var maximumY: Int64 = -1
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            if (input.pixels[(y * input.width + x) * 4 + 3] > 0) {
                if (x < minimumX) {
                    minimumX = x
                }
                if (x > maximumX) {
                    maximumX = x
                }
                if (y < minimumY) {
                    minimumY = y
                }
                if (y > maximumY) {
                    maximumY = y
                }
            }
            x++
        }
        y++
    }
    if (maximumX < 0 || maximumY < 0) {
        return Array<Int64>()
    }
    [minimumX, minimumY, maximumX - minimumX + 1, maximumY - minimumY + 1]
}

private func positiveMod(value: Int64, modulus: Int64): Int64 {
    if (modulus <= 0) {
        return 0
    }
    let remainder = value % modulus
    if (remainder < 0) {
        remainder + modulus
    } else {
        remainder
    }
}
