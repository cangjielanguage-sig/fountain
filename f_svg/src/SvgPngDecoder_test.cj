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
import std.io.{ByteBuffer, InputStream}
import std.unittest.*
import std.unittest.testmacro.*
import stdx.compress.zlib.{CompressOutputStream, WrapType}

internal func pngBe32(value: Int64): Array<Byte> {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

internal func pngChunk(out: ByteBuffer, kind: String, data: Array<Byte>): Unit {
    let kindBytes = kind.toArray()
    out.write(pngBe32(Int64(data.size)))
    out.write(kindBytes)
    out.write(data)
    let crcInput = ByteBuffer()
    crcInput.write(kindBytes)
    crcInput.write(data)
    out.write(pngBe32(SvgCrc32.checksum(crcInput.bytes())))
}

internal func pngAdler32(data: Array<Byte>): Int64 {
    var first: Int64 = 1
    var second: Int64 = 0
    for (byte in data) {
        first = (first + Int64(byte)) % 65521
        second = (second + first) % 65521
    }
    second * 65536 + first
}

internal func pngZlib(data: Array<Byte>): Array<Byte> {
    let compressed = ByteBuffer()
    let compressor = CompressOutputStream(compressed, wrap: WrapType.DeflateFormat)
    compressor.write(data)
    compressor.close()
    let out = ByteBuffer()
    out.write([0x78, 0x9C])
    out.write(compressed.bytes())
    out.write(pngBe32(pngAdler32(data)))
    out.bytes()
}

internal func pngPrefix(
    width: Int64,
    height: Int64,
    bitDepth: Int64,
    colorType: Int64,
    interlace: Int64
): ByteBuffer {
    let out = ByteBuffer()
    out.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let header = ByteBuffer()
    header.write(pngBe32(width))
    header.write(pngBe32(height))
    header.write([UInt8(bitDepth), UInt8(colorType), 0, 0, UInt8(interlace)])
    pngChunk(out, "IHDR", header.bytes())
    out
}

internal func buildPng(
    width: Int64,
    height: Int64,
    bitDepth: Int64,
    colorType: Int64,
    interlace: Int64,
    raw: Array<Byte>,
    plte!: Array<Byte> = Array<Byte>(),
    trns!: Array<Byte> = Array<Byte>()
): Array<Byte> {
    let out = pngPrefix(width, height, bitDepth, colorType, interlace)
    if (plte.size > 0) {
        pngChunk(out, "PLTE", plte)
    }
    if (trns.size > 0) {
        pngChunk(out, "tRNS", trns)
    }
    pngChunk(out, "IDAT", pngZlib(raw))
    pngChunk(out, "IEND", Array<Byte>())
    out.bytes()
}

internal func pngPaeth(left: Int64, up: Int64, upLeft: Int64): Int64 {
    let estimate = left + up - upLeft
    let distanceLeft = if (estimate > left) {
        estimate - left
    } else {
        left - estimate
    }
    let distanceUp = if (estimate > up) {
        estimate - up
    } else {
        up - estimate
    }
    let distanceUpLeft = if (estimate > upLeft) {
        estimate - upLeft
    } else {
        upLeft - estimate
    }
    if (distanceLeft <= distanceUp && distanceLeft <= distanceUpLeft) {
        left
    } else if (distanceUp <= distanceUpLeft) {
        up
    } else {
        upLeft
    }
}

internal func pngForwardFilter(
    raw: Array<Byte>,
    previous: Array<Byte>,
    filter: Int64,
    bpp: Int64
): Array<Byte> {
    let out = Array<Byte>(raw.size, repeat: 0)
    for (index in 0..raw.size) {
        let left = if (index >= bpp) {
            Int64(raw[index - bpp])
        } else {
            0
        }
        let up = Int64(previous[index])
        let upLeft = if (index >= bpp) {
            Int64(previous[index - bpp])
        } else {
            0
        }
        let predicted = match (filter) {
            case 1 => left
            case 2 => up
            case 3 => (left + up) / 2
            case 4 => pngPaeth(left, up, upLeft)
            case _ => 0
        }
        out[index] = UInt8((Int64(raw[index]) - predicted + 256) % 256)
    }
    out
}

/** 按目标 RGBA 像素生成 Adam7 原始扫描行（filter 0）。 */
internal func pngAdam7Raw(pixels: Array<Byte>, width: Int64, height: Int64): Array<Byte> {
    let out = ByteBuffer()
    let origins: Array<(Int64, Int64, Int64, Int64)> = [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)
    ]
    for (origin in origins) {
        let (x0, y0, stepX, stepY) = origin
        if (x0 >= width || y0 >= height) {
            continue
        }
        var passWidth = (width - x0 + stepX - 1) / stepX
        var passHeight = (height - y0 + stepY - 1) / stepY
        var row = 0
        while (row < passHeight) {
            out.write([UInt8(0)])
            var column = 0
            while (column < passWidth) {
                let x = x0 + column * stepX
                let y = y0 + row * stepY
                let base = (y * width + x) * 4
                out.write(pixels[base..base + 4])
                column++
            }
            row++
        }
    }
    out.bytes()
}

@Test
public class SvgPngDecoder_test {
    /** 最小 1×1 RGBA，像素精确。 */
    @TestCase
    public func minimalRgba(): Unit {
        let bytes = buildPng(1, 1, 8, 6, 0, [0, 255, 0, 0, 255])
        let bitmap = SvgPngDecoder.decode(bytes)
        @Assert(bitmap.width == 1)
        @Assert(bitmap.height == 1)
        @Assert(bitmap.pixels == [255, 0, 0, 255])
    }

    /** 签名与 IHDR 校验。 */
    @TestCase
    public func signatureAndHeaderValidation(): Unit {
        let bytes = buildPng(1, 1, 8, 6, 0, [0, 255, 0, 0, 255])

        let badSignature = Array<Byte>(bytes.size, repeat: 0)
        for (index in 0..bytes.size) {
            badSignature[index] = bytes[index]
        }
        badSignature[0] = 0x00
        @Assert(expectSvgException({=> SvgPngDecoder.decode(badSignature)}).kind == SvgErrorKind.Syntax)

        let badLength = ByteBuffer()
        badLength.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let shortHeader = Array<Byte>(12, repeat: 0)
        pngChunk(badLength, "IHDR", shortHeader)
        pngChunk(badLength, "IEND", Array<Byte>())
        @Assert(expectSvgException({=> SvgPngDecoder.decode(badLength.bytes())}).kind == SvgErrorKind.Syntax)

        let unknownType = buildPng(1, 1, 8, 5, 0, [0, 0, 0, 0])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(unknownType)}).kind == SvgErrorKind.InvalidValue)

        let bit16 = buildPng(1, 1, 16, 6, 0, [0, 0, 0, 0, 0, 0, 0, 0])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(bit16)}).kind == SvgErrorKind.InvalidValue)
    }

    /** 灰度 8-bit 与 4-bit 展开。 */
    @TestCase
    public func grayVariants(): Unit {
        let gray8 = buildPng(2, 1, 8, 0, 0, [0, 0x00, 0xFF])
        let bitmap8 = SvgPngDecoder.decode(gray8)
        @Assert(bitmap8.pixels == [0, 0, 0, 255, 255, 255, 255, 255])

        let gray4 = buildPng(1, 1, 4, 0, 0, [0, 0xF0])
        let bitmap4 = SvgPngDecoder.decode(gray4)
        @Assert(bitmap4.pixels == [255, 255, 255, 255])

        let gray1 = buildPng(1, 1, 1, 0, 0, [0, 0x80])
        @Assert(SvgPngDecoder.decode(gray1).pixels == [255, 255, 255, 255])

        let gray2 = buildPng(2, 1, 2, 0, 0, [0, 0xC0])
        let bitmap2 = SvgPngDecoder.decode(gray2)
        @Assert(bitmap2.pixels == [255, 255, 255, 255, 0, 0, 0, 255])
    }

    /** 灰度+α 与 RGB。 */
    @TestCase
    public func grayAlphaAndRgb(): Unit {
        let grayAlpha = buildPng(1, 1, 8, 4, 0, [0, 128, 64])
        @Assert(SvgPngDecoder.decode(grayAlpha).pixels == [128, 128, 128, 64])

        let rgb = buildPng(1, 1, 8, 2, 0, [0, 255, 0, 0])
        @Assert(SvgPngDecoder.decode(rgb).pixels == [255, 0, 0, 255])
    }

    /** 调色板与 tRNS。 */
    @TestCase
    public func paletteAndTransparency(): Unit {
        let palette: Array<Byte> = [0, 255, 0, 255, 0, 0]
        let palettePng = buildPng(1, 1, 4, 3, 0, [0, 0x10], plte: palette)
        @Assert(SvgPngDecoder.decode(palettePng).pixels == [255, 0, 0, 255])

        let trnsPalette = buildPng(1, 1, 4, 3, 0, [0, 0x10], plte: palette, trns: [0, 128])
        @Assert(SvgPngDecoder.decode(trnsPalette).pixels == [255, 0, 0, 128])

        let rgbTrns = buildPng(2, 1, 8, 2, 0, [0, 0, 255, 0, 255, 0, 0], trns: [0, 0, 0, 255, 0, 0])
        @Assert(SvgPngDecoder.decode(rgbTrns).pixels == [0, 255, 0, 0, 255, 0, 0, 255])

        let outOfRange = buildPng(1, 1, 4, 3, 0, [0, 0x20], plte: palette)
        @Assert(expectSvgException({=> SvgPngDecoder.decode(outOfRange)}).kind == SvgErrorKind.Syntax)

        let badPalette = buildPng(1, 1, 4, 3, 0, [0, 0x00], plte: [1, 2, 3, 4])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(badPalette)}).kind == SvgErrorKind.Syntax)
    }

    /** filter 0–4 逐行逆运算。 */
    @TestCase
    public func filterTypesRoundTrip(): Unit {
        let width = 4
        let height = 5
        let bpp = 3
        let out = pngPrefix(width, height, 8, 2, 0)
        let expected = ArrayList<Byte>()
        var previous = Array<Byte>(width * bpp, repeat: 0)
        var row = 0
        while (row < height) {
            let raw = Array<Byte>(width * bpp, repeat: 0)
            for (index in 0..raw.size) {
                raw[index] = UInt8((index * 7 + row * 13) % 256)
                expected.add(raw[index])
            }
            let encoded = pngForwardFilter(raw, previous, row, bpp)
            let scanline = ByteBuffer()
            scanline.write([UInt8(row)])
            scanline.write(encoded)
            previous = raw
            row++
        }
        // 重新按行拼接后压缩。
        let rawAll = ByteBuffer()
        previous = Array<Byte>(width * bpp, repeat: 0)
        row = 0
        while (row < height) {
            let raw = Array<Byte>(width * bpp, repeat: 0)
            for (index in 0..raw.size) {
                raw[index] = UInt8((index * 7 + row * 13) % 256)
            }
            rawAll.write([UInt8(row)])
            rawAll.write(pngForwardFilter(raw, previous, row, bpp))
            previous = raw
            row++
        }
        pngChunk(out, "IDAT", pngZlib(rawAll.bytes()))
        pngChunk(out, "IEND", Array<Byte>())
        let bitmap = SvgPngDecoder.decode(out.bytes())
        var pixelIndex = 0
        row = 0
        while (row < height) {
            var column = 0
            while (column < width) {
                let base = (row * width + column) * 4
                let expectedBase = (row * width + column) * 3
                @Assert(bitmap.pixels[base] == expected[expectedBase])
                @Assert(bitmap.pixels[base + 1] == expected[expectedBase + 1])
                @Assert(bitmap.pixels[base + 2] == expected[expectedBase + 2])
                @Assert(bitmap.pixels[base + 3] == 255)
                column++
                pixelIndex++
            }
            row++
        }

        let invalidFilter = pngPrefix(1, 1, 8, 2, 0)
        pngChunk(invalidFilter, "IDAT", pngZlib([5, 1, 2, 3]))
        pngChunk(invalidFilter, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(invalidFilter.bytes())}).kind ==
                SvgErrorKind.InvalidValue
        )
    }

    /** Adam7 与非交错逐像素一致。 */
    @TestCase
    public func adam7MatchesProgressive(): Unit {
        let width = 8
        let height = 8
        let pixels = Array<Byte>(width * height * 4, repeat: 0)
        for (index in 0..pixels.size) {
            pixels[index] = UInt8((index * 37 + 11) % 256)
        }
        let progressiveRaw = ByteBuffer()
        for (row in 0..height) {
            progressiveRaw.write([UInt8(0)])
            for (column in 0..width) {
                let base = (row * width + column) * 4
                progressiveRaw.write(pixels[base..base + 4])
            }
        }
        let progressive = buildPng(width, height, 8, 6, 0, progressiveRaw.bytes())
        let interlaced = buildPng(width, height, 8, 6, 1, pngAdam7Raw(pixels, width, height))
        let first = SvgPngDecoder.decode(progressive)
        let second = SvgPngDecoder.decode(interlaced)
        @Assert(first.pixels == second.pixels)
        @Assert(first.pixels == pixels)
    }

    /** chunk 状态机：CRC、截断、缺 IEND、IDAT 不连续、IHDR 非首个。 */
    @TestCase
    public func chunkStateMachine(): Unit {
        let valid = buildPng(1, 1, 8, 6, 0, [0, 255, 0, 0, 255])

        let badCrc = Array<Byte>(valid.size, repeat: 0)
        for (index in 0..valid.size) {
            badCrc[index] = valid[index]
        }
        badCrc[badCrc.size - 16] = UInt8(Int64(badCrc[badCrc.size - 16]) ^ 0xFF)
        @Assert(expectSvgException({=> SvgPngDecoder.decode(badCrc)}).kind == SvgErrorKind.Syntax)

        let noIend = valid[0..valid.size - 12]
        @Assert(expectSvgException({=> SvgPngDecoder.decode(noIend)}).kind == SvgErrorKind.Syntax)

        let compressed = pngZlib([0, 255, 0, 0, 255])
        let truncatedStream = pngPrefix(1, 1, 8, 6, 0)
        pngChunk(truncatedStream, "IDAT", compressed[0..compressed.size - 2])
        pngChunk(truncatedStream, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(truncatedStream.bytes())}).kind ==
                SvgErrorKind.Syntax
        )

        let nonConsecutive = pngPrefix(1, 1, 8, 6, 0)
        pngChunk(nonConsecutive, "IDAT", compressed)
        pngChunk(nonConsecutive, "tEXt", "a".toArray())
        pngChunk(nonConsecutive, "IDAT", Array<Byte>())
        pngChunk(nonConsecutive, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(nonConsecutive.bytes())}).kind ==
                SvgErrorKind.Syntax
        )

        let headerNotFirst = ByteBuffer()
        headerNotFirst.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        pngChunk(headerNotFirst, "tEXt", "a".toArray())
        let header = ByteBuffer()
        header.write(pngBe32(1))
        header.write(pngBe32(1))
        header.write([8, 6, 0, 0, 0])
        pngChunk(headerNotFirst, "IHDR", header.bytes())
        pngChunk(headerNotFirst, "IDAT", compressed)
        pngChunk(headerNotFirst, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(headerNotFirst.bytes())}).kind ==
                SvgErrorKind.Syntax
        )
    }

    /** 解压长度不匹配。 */
    @TestCase
    public func decompressedLengthMismatch(): Unit {
        let extra = pngPrefix(1, 1, 8, 6, 0)
        pngChunk(extra, "IDAT", pngZlib([0, 1, 2, 3, 4, 5, 6, 7, 8]))
        pngChunk(extra, "IEND", Array<Byte>())
        @Assert(expectSvgException({=> SvgPngDecoder.decode(extra.bytes())}).kind == SvgErrorKind.Syntax)

        let short = pngPrefix(1, 1, 8, 6, 0)
        pngChunk(short, "IDAT", pngZlib([0, 1, 2]))
        pngChunk(short, "IEND", Array<Byte>())
        @Assert(expectSvgException({=> SvgPngDecoder.decode(short.bytes())}).kind == SvgErrorKind.Syntax)
    }

    /** 像素上限在解压前检查。 */
    @TestCase
    public func pixelLimits(): Unit {
        let huge = pngPrefix(5000, 5000, 8, 6, 0)
        pngChunk(huge, "IDAT", Array<Byte>())
        pngChunk(huge, "IEND", Array<Byte>())
        @Assert(expectSvgException({=> SvgPngDecoder.decode(huge.bytes())}).kind == SvgErrorKind.Limit)

        let gigantic = pngPrefix(100000, 100000, 8, 6, 0)
        pngChunk(gigantic, "IDAT", Array<Byte>())
        pngChunk(gigantic, "IEND", Array<Byte>())
        @Assert(expectSvgException({=> SvgPngDecoder.decode(gigantic.bytes())}).kind == SvgErrorKind.Limit)

        let okBytes = buildPng(2, 2, 8, 6, 0, Array<Byte>(2 * (1 + 2 * 4), repeat: 0))
        let budget = SvgDecodeBudget(3)
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(okBytes, budget: budget)}).kind ==
                SvgErrorKind.Limit
        )
    }

    /** 编码 → 解码回环，含全透明像素。 */
    @TestCase
    public func encoderRoundTrip(): Unit {
        let bitmap = SvgBitmap(8, 8)
        for (index in 0..bitmap.pixels.size) {
            bitmap.pixels[index] = UInt8((index * 19 + 3) % 256)
        }
        bitmap.pixels[0] = 0
        bitmap.pixels[1] = 0
        bitmap.pixels[2] = 0
        bitmap.pixels[3] = 0
        let decoded = SvgPngDecoder.decode(bitmap.toPngBytes())
        @Assert(decoded.width == 8 && decoded.height == 8)
        @Assert(decoded.pixels == bitmap.pixels)
    }

    /** 输入不被修改，重复解码结果一致。 */
    @TestCase
    public func inputImmutable(): Unit {
        let bytes = buildPng(2, 1, 8, 6, 0, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        let copy = Array<Byte>(bytes.size, repeat: 0)
        for (index in 0..bytes.size) {
            copy[index] = bytes[index]
        }
        let first = SvgPngDecoder.decode(bytes)
        let second = SvgPngDecoder.decode(bytes)
        @Assert(first.pixels == second.pixels)
        @Assert(bytes == copy)
    }
}

@Test
public class SvgPngChunkErrorM3_test {
    /** 未知关键 chunk 属于结构错误，抛 Syntax。 */
    @TestCase
    public func unknownCriticalChunkIsSyntax(): Unit {
        let out = pngPrefix(1, 1, 8, 6, 0)
        pngChunk(out, "ZZZZ", [1, 2, 3])
        pngChunk(out, "IDAT", pngZlib([0, 255, 0, 0, 255]))
        pngChunk(out, "IEND", Array<Byte>())
        let error = expectSvgException({=> SvgPngDecoder.decode(out.bytes())})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }
}

@Test
public class SvgPngStructureM3_test {
    /** tRNS 长度必须与颜色类型匹配。 */
    @TestCase
    public func invalidTrnsLength(): Unit {
        let gray = buildPng(1, 1, 8, 0, 0, [0, 128], trns: [0, 128, 0])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(gray)}).kind == SvgErrorKind.Syntax)
        let rgb = buildPng(1, 1, 8, 2, 0, [0, 1, 2, 3], trns: [0, 1])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(rgb)}).kind == SvgErrorKind.Syntax)
        let rgba = buildPng(1, 1, 8, 6, 0, [0, 1, 2, 3, 4], trns: [0, 1, 2, 3, 4, 5])
        @Assert(expectSvgException({=> SvgPngDecoder.decode(rgba)}).kind == SvgErrorKind.Syntax)
    }

    /** 重复 IHDR、空 PLTE、调色板缺 PLTE 均为 Syntax。 */
    @TestCase
    public func structuralVariants(): Unit {
        let duplicate = pngPrefix(1, 1, 8, 6, 0)
        let header = ByteBuffer()
        header.write(pngBe32(1))
        header.write(pngBe32(1))
        header.write([8, 6, 0, 0, 0])
        pngChunk(duplicate, "IHDR", header.bytes())
        pngChunk(duplicate, "IDAT", pngZlib([0, 255, 0, 0, 255]))
        pngChunk(duplicate, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(duplicate.bytes())}).kind ==
                SvgErrorKind.Syntax
        )

        let emptyPalette = pngPrefix(1, 1, 8, 2, 0)
        pngChunk(emptyPalette, "PLTE", Array<Byte>())
        pngChunk(emptyPalette, "IDAT", pngZlib([0, 1, 2, 3]))
        pngChunk(emptyPalette, "IEND", Array<Byte>())
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(emptyPalette.bytes())}).kind ==
                SvgErrorKind.Syntax
        )

        let missingPalette = buildPng(1, 1, 4, 3, 0, [0, 0x10])
        @Assert(
            expectSvgException({=> SvgPngDecoder.decode(missingPalette)}).kind ==
                SvgErrorKind.Syntax
        )
    }
}

internal class SvgEndlessZeroStream <: InputStream {
    private var remaining: Int64

    init(remaining: Int64) {
        this.remaining = remaining
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.remaining <= 0) {
            return 0
        }
        var count = this.remaining
        if (count > buffer.size) {
            count = buffer.size
        }
        for (index in 0..count) {
            buffer[index] = 0
        }
        this.remaining -= count
        count
    }
}

@Test
public class SvgPngStreamLimitM3_test {
    /** decode(stream) 读取总量超过上限时抛 Limit。 */
    @TestCase
    public func streamByteLimit(): Unit {
        let stream = SvgEndlessZeroStream(SVG_MAX_PNG_STREAM_BYTES + 1)
        let error = expectSvgException({=> SvgPngDecoder.decode(stream)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}
