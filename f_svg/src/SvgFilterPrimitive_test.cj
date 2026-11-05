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
import std.unittest.*
import std.unittest.testmacro.*

internal func solidBuffer(width: Int64, height: Int64, color: SvgColor): SvgFilterBuffer {
    let buffer = SvgFilterBuffer(width, height)
    var index = 0
    while (index < buffer.pixels.size) {
        buffer.pixels[index] = UInt8(Int64(color.red))
        buffer.pixels[index + 1] = UInt8(Int64(color.green))
        buffer.pixels[index + 2] = UInt8(Int64(color.blue))
        buffer.pixels[index + 3] = UInt8(Int64(round(color.alpha * 255.0)))
        index += 4
    }
    buffer
}

internal func setBufferPixel(
    buffer: SvgFilterBuffer,
    x: Int64,
    y: Int64,
    red: Int64,
    green: Int64,
    blue: Int64,
    alpha: Int64
): Unit {
    let base = (y * buffer.width + x) * 4
    buffer.pixels[base] = UInt8(red)
    buffer.pixels[base + 1] = UInt8(green)
    buffer.pixels[base + 2] = UInt8(blue)
    buffer.pixels[base + 3] = UInt8(alpha)
}

internal func bufferPixel(
    buffer: SvgFilterBuffer,
    x: Int64,
    y: Int64
): Array<Byte> {
    let base = (y * buffer.width + x) * 4
    [buffer.pixels[base], buffer.pixels[base + 1], buffer.pixels[base + 2], buffer.pixels[base + 3]]
}

@Test
public class SvgFilterPrimitive_test {
    /** 高斯模糊：σ=0 直通；单值对称扩散；双值只在一个方向扩散。 */
    @TestCase
    public func gaussianBlur(): Unit {
        let impulse = SvgFilterBuffer(9, 9)
        setBufferPixel(impulse, 4, 4, 255, 255, 255, 255)

        let plain = blurFilterBuffer(impulse, 0.0, 0.0)
        @Assert(plain.pixels == impulse.pixels)

        let blurred = blurFilterBuffer(impulse, 1.0, 1.0)
        @Assert(blurred.pixels[(4 * 9 + 4) * 4 + 3] < 255)
        @Assert(blurred.pixels[(4 * 9 + 3) * 4 + 3] > 0)
        @Assert(blurred.pixels[(4 * 9 + 5) * 4 + 3] == blurred.pixels[(4 * 9 + 3) * 4 + 3])
        @Assert(blurred.pixels[(4 * 9 + 4) * 4 + 3] > 0)
        @Assert(blurred.pixels[(3 * 9 + 4) * 4 + 3] == blurred.pixels[(5 * 9 + 4) * 4 + 3])

        let horizontalOnly = blurFilterBuffer(impulse, 0.0, 2.0)
        @Assert(horizontalOnly.pixels[(4 * 9 + 6) * 4 + 3] == 0)
        @Assert(horizontalOnly.pixels[(6 * 9 + 4) * 4 + 3] > 0)
    }

    /** 偏移：正负方向与越界透明。 */
    @TestCase
    public func offset(): Unit {
        let input = SvgFilterBuffer(3, 3)
        setBufferPixel(input, 0, 0, 255, 0, 0, 255)

        let right = offsetFilterBuffer(input, 1, 0)
        @Assert(bufferPixel(right, 1, 0) == [255, 0, 0, 255])
        @Assert(bufferPixel(right, 0, 0) == [0, 0, 0, 0])

        let left = offsetFilterBuffer(input, -1, 0)
        @Assert(bufferPixel(left, 0, 0) == [0, 0, 0, 0])

        let down = offsetFilterBuffer(input, 0, 2)
        @Assert(bufferPixel(down, 0, 2) == [255, 0, 0, 255])
    }

    /** 洪水填充颜色 × 不透明度。 */
    @TestCase
    public func flood(): Unit {
        let output = floodFilterBuffer(2, 2, SvgColor.fromRgb(0, 255, 0), 0.5)
        @Assert(bufferPixel(output, 0, 0) == [0, 255, 0, 128])
        @Assert(bufferPixel(output, 1, 1) == [0, 255, 0, 128])
    }

    /** 混合：normal 等价 over；multiply 红 × 蓝为黑。 */
    @TestCase
    public func blend(): Unit {
        let red = solidBuffer(2, 2, SvgColor.fromRgb(255, 0, 0))
        let blue = solidBuffer(2, 2, SvgColor.fromRgb(0, 0, 255))
        let multiplied = blendFilterBuffer(red, blue, SvgBlendMode.Multiply)
        @Assert(bufferPixel(multiplied, 0, 0) == [0, 0, 0, 255])

        let normal = blendFilterBuffer(red, blue, SvgBlendMode.Normal)
        let over = compositeFilterBuffer(red, blue, SvgCompositeOperator.Over, 0.0, 0.0, 0.0, 0.0)
        @Assert(normal.pixels == over.pixels)

        let screen = blendFilterBuffer(red, blue, SvgBlendMode.Screen)
        @Assert(bufferPixel(screen, 0, 0) == [255, 0, 255, 255])
        let darken = blendFilterBuffer(red, blue, SvgBlendMode.Darken)
        @Assert(bufferPixel(darken, 0, 0) == [0, 0, 0, 255])
        let lighten = blendFilterBuffer(red, blue, SvgBlendMode.Lighten)
        @Assert(bufferPixel(lighten, 0, 0) == [255, 0, 255, 255])
    }

    /** 合成：五种 Porter-Duff 与 arithmetic 钳制。 */
    @TestCase
    public func composite(): Unit {
        let red = solidBuffer(2, 2, SvgColor.fromRgb(255, 0, 0))
        let blue = solidBuffer(2, 2, SvgColor.fromRgb(0, 0, 255))

        @Assert(bufferPixel(compositeFilterBuffer(red, blue, SvgCompositeOperator.Over, 0.0, 0.0, 0.0, 0.0), 0, 0) == [255, 0, 0, 255])
        @Assert(bufferPixel(compositeFilterBuffer(red, blue, SvgCompositeOperator.In, 0.0, 0.0, 0.0, 0.0), 0, 0) == [255, 0, 0, 255])
        @Assert(bufferPixel(compositeFilterBuffer(red, blue, SvgCompositeOperator.Out, 0.0, 0.0, 0.0, 0.0), 0, 0) == [0, 0, 0, 0])
        @Assert(bufferPixel(compositeFilterBuffer(red, blue, SvgCompositeOperator.Atop, 0.0, 0.0, 0.0, 0.0), 0, 0) == [255, 0, 0, 255])
        @Assert(bufferPixel(compositeFilterBuffer(red, blue, SvgCompositeOperator.Xor, 0.0, 0.0, 0.0, 0.0), 0, 0) == [0, 0, 0, 0])

        let half = solidBuffer(1, 1, SvgColor(128, 0, 0, alpha: 1.0))
        let arithmetic = compositeFilterBuffer(
            half,
            half,
            SvgCompositeOperator.Arithmetic,
            0.0,
            1.0,
            1.0,
            0.0
        )
        @Assert(bufferPixel(arithmetic, 0, 0) == [255, 0, 0, 255])
    }

    /** merge 顺序与缺省输入。 */
    @TestCase
    public func merge(): Unit {
        let red = solidBuffer(2, 2, SvgColor.fromRgb(255, 0, 0))
        let halfBlue = solidBuffer(2, 2, SvgColor(0, 0, 255, alpha: 0.5))
        let buffers = ArrayList<SvgFilterBuffer>()
        buffers.add(red)
        buffers.add(halfBlue)
        let merged = mergeFilterBuffers(buffers)
        let pixel = bufferPixel(merged, 0, 0)
        @Assert(pixel[0] == 127 && pixel[1] == 0 && pixel[2] == 128 && pixel[3] == 255)
    }

    /** 颜色矩阵：亮度转 alpha、20 值矩阵、饱和度、值个数不符直通。 */
    @TestCase
    public func colorMatrix(): Unit {
        let white = solidBuffer(1, 1, SvgColor.fromRgb(255, 255, 255))
        let luminance = colorMatrixFilterBuffer(
            white,
            SvgColorMatrixType.LuminanceToAlpha,
            Array<Float64>(),
            ArrayList<String>()
        )
        @Assert(bufferPixel(luminance, 0, 0) == [0, 0, 0, 255])

        let identityValues: Array<Float64> = [
            1.0, 0.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 1.0, 0.0
        ]
        let identity = colorMatrixFilterBuffer(
            white,
            SvgColorMatrixType.Matrix,
            identityValues,
            ArrayList<String>()
        )
        @Assert(identity.pixels == white.pixels)

        let gray = solidBuffer(1, 1, SvgColor.fromRgb(255, 0, 0))
        let saturated = colorMatrixFilterBuffer(
            gray,
            SvgColorMatrixType.Saturate,
            [0.0],
            ArrayList<String>()
        )
        let pixel = bufferPixel(saturated, 0, 0)
        @Assert(pixel[0] == pixel[1] && pixel[1] == pixel[2])

        let warnings = ArrayList<String>()
        let passthrough = colorMatrixFilterBuffer(
            gray,
            SvgColorMatrixType.Matrix,
            [1.0, 0.0],
            warnings
        )
        @Assert(passthrough.pixels == gray.pixels)
        @Assert(warnings.size >= 1)
    }

    /** 平铺：2×2 输入平铺到 6×6。 */
    @TestCase
    public func tile(): Unit {
        let input = SvgFilterBuffer(2, 2)
        setBufferPixel(input, 0, 0, 255, 0, 0, 255)
        setBufferPixel(input, 1, 0, 0, 255, 0, 255)
        setBufferPixel(input, 0, 1, 0, 0, 255, 255)
        setBufferPixel(input, 1, 1, 255, 255, 0, 255)
        let tiled = tileFilterBuffer(input, 6, 6)
        @Assert(tiled.width == 6 && tiled.height == 6)
        @Assert(bufferPixel(tiled, 0, 0) == [255, 0, 0, 255])
        @Assert(bufferPixel(tiled, 5, 5) == [255, 255, 0, 255])
        @Assert(bufferPixel(tiled, 4, 2) == [255, 0, 0, 255])
    }

    /** blur + offset + merge 组合。 */
    @TestCase
    public func blurOffsetMergeGolden(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><filter id=\"f\" x=\"0\" y=\"0\" width=\"20\" height=\"20\" " +
            "filterUnits=\"userSpaceOnUse\">" +
            "<feGaussianBlur stdDeviation=\"1\" result=\"blur\"/>" +
            "<feOffset in=\"blur\" dx=\"5\" dy=\"5\" result=\"shifted\"/>" +
            "<feMerge><feMergeNode in=\"shifted\"/><feMergeNode in=\"SourceGraphic\"/></feMerge>" +
            "</filter></defs>" +
            "<rect x=\"0\" y=\"0\" width=\"4\" height=\"4\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let shifted = bitmap.pixel(7, 7)
        @Assert(shifted.red > 0)
        let original = bitmap.pixel(1, 1)
        @Assert(original.red > 0)
        @Assert(bitmap.pixel(19, 19).alpha == 0.0)
    }
}
