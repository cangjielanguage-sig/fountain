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

import std.io.{ByteBuffer, InputStream}
import stdx.compress.zlib.{DecompressInputStream, WrapType, ZlibException}
import fountain::f_base.*

/** 单张 PNG 解码像素上限。 */
internal let SVG_MAX_IMAGE_PIXELS: Int64 = 16 * 1024 * 1024
/** 单次渲染累计解码像素上限。 */
internal let SVG_MAX_RENDER_DECODE_PIXELS: Int64 = 64 * 1024 * 1024

/** 单次渲染共享的解码像素预算；在分配位图前扣减。 */
internal class SvgDecodeBudget {
    private var remaining: Int64

    init(total: Int64) {
        if (total <= 0) {
            throw invalidValue("解码像素预算必须为正，实际 ${total}")
        }
        this.remaining = total
    }

    func consume(pixels: Int64): Unit {
        if (pixels < 0) {
            throw invalidValue("解码像素数不能为负")
        }
        if (pixels > this.remaining) {
            throw SvgException(
                "单次渲染累计解码像素超过上限 ${SVG_MAX_RENDER_DECODE_PIXELS}",
                kind: SvgErrorKind.Limit
            )
        }
        this.remaining -= pixels
    }
}

/**
 * PNG 解码器：RGBA8 非预乘输出。
 *
 * 支持颜色类型 0/2/3/4/6、位深 1/2/4/8、filter 0–4、Adam7 与 tRNS。
 * 结构错误 `Syntax`、非法组合 `InvalidValue`、超限 `Limit`。
 */
public class SvgPngDecoder {
    public static func decode(bytes: Array<Byte>): SvgBitmap {
        decode(bytes, budget: None)
    }

    public static func decode(stream: InputStream): SvgBitmap {
        let out = ByteBuffer()
        let buffer = Array<Byte>(8192, repeat: 0)
        var count = stream.read(buffer)
        while (count > 0) {
            out.write(buffer[0..count])
            count = stream.read(buffer)
        }
        decode(out.bytes())
    }

    internal static func decode(bytes: Array<Byte>, budget!: ?SvgDecodeBudget): SvgBitmap {
        let header = readHeaderChunks(bytes)
        // 宽高来自 32 位无符号整数，先用除法判断，避免 width * height 溢出。
        if (header.width > 0x7FFFFFFF || header.height > 0x7FFFFFFF ||
            header.width > SVG_MAX_IMAGE_PIXELS / header.height) {
            throw SvgException(
                "PNG 像素数超过单图上限 ${SVG_MAX_IMAGE_PIXELS}",
                kind: SvgErrorKind.Limit
            )
        }
        let pixels = header.width * header.height
        if (pixels > SVG_MAX_IMAGE_PIXELS) {
            throw SvgException(
                "PNG 像素数 ${pixels} 超过单图上限 ${SVG_MAX_IMAGE_PIXELS}",
                kind: SvgErrorKind.Limit
            )
        }
        match (budget) {
            case Some(decoderBudget) => decoderBudget.consume(pixels)
            case None => ()
        }
        validateColorCombination(header.bitDepth, header.colorType)
        if (header.colorType == 3 && header.palette.size == 0) {
            throw SvgException("调色板 PNG 缺少 PLTE", kind: SvgErrorKind.Syntax)
        }
        if (header.colorType == 3 && header.palette.size % 3 != 0) {
            throw SvgException("PLTE 长度不是 3 的倍数", kind: SvgErrorKind.Syntax)
        }
        if (header.colorType == 3 && header.transparency.size > header.palette.size / 3) {
            throw SvgException("tRNS 长于调色板", kind: SvgErrorKind.Syntax)
        }
        let channels = channelCount(header.colorType)
        let bitsPerPixel = channels * header.bitDepth
        let bytesPerPixel = (bitsPerPixel + 7) / 8
        let bpp = if (bytesPerPixel < 1) {
            1
        } else {
            bytesPerPixel
        }
        let bitmap = SvgBitmap(header.width, header.height)
        if (header.interlace == 0) {
            let rowBytes = (header.width * bitsPerPixel + 7) / 8
            let expected = header.height * (1 + rowBytes)
            let raw = inflateZlib(header.idat, expected)
            var previous = Array<Byte>(rowBytes, repeat: 0)
            var row = 0
            while (row < header.height) {
                let offset = row * (1 + rowBytes)
                let filter = Int64(raw[offset])
                let current = reverseFilter(raw[offset + 1..offset + 1 + rowBytes], previous, filter, bpp)
                writeScanline(
                    bitmap, current, header.width, header.bitDepth, header.colorType,
                    header.palette, header.transparency, 0, 0, 1, 1, row
                )
                previous = current
                row++
            }
        } else {
            decodeAdam7(bitmap, header, bitsPerPixel, bpp)
        }
        bitmap
    }

    private static func decodeAdam7(
        bitmap: SvgBitmap,
        header: SvgPngHeader,
        bitsPerPixel: Int64,
        bpp: Int64
    ): Unit {
        let origins: Array<(Int64, Int64, Int64, Int64)> = [
            (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
            (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)
        ]
        var expected: Int64 = 0
        for (origin in origins) {
            let (x0, y0, stepX, stepY) = origin
            if (x0 >= header.width || y0 >= header.height) {
                continue
            }
            let passWidth = (header.width - x0 + stepX - 1) / stepX
            let passHeight = (header.height - y0 + stepY - 1) / stepY
            let rowBytes = (passWidth * bitsPerPixel + 7) / 8
            expected += passHeight * (1 + rowBytes)
        }
        let raw = inflateZlib(header.idat, expected)
        var offset: Int64 = 0
        for (origin in origins) {
            let (x0, y0, stepX, stepY) = origin
            if (x0 >= header.width || y0 >= header.height) {
                continue
            }
            let passWidth = (header.width - x0 + stepX - 1) / stepX
            let passHeight = (header.height - y0 + stepY - 1) / stepY
            let rowBytes = (passWidth * bitsPerPixel + 7) / 8
            var previous = Array<Byte>(rowBytes, repeat: 0)
            var row = 0
            while (row < passHeight) {
                let filter = Int64(raw[offset])
                let current = reverseFilter(
                    raw[offset + 1..offset + 1 + rowBytes],
                    previous,
                    filter,
                    bpp
                )
                writeScanline(
                    bitmap, current, passWidth, header.bitDepth, header.colorType,
                    header.palette, header.transparency, x0, y0, stepX, stepY, row
                )
                previous = current
                offset += 1 + rowBytes
                row++
            }
        }
    }
}

/** IHDR 与关键 chunk 的解析结果。 */
private class SvgPngHeader {
    init() {}

    var width: Int64 = 0
    var height: Int64 = 0
    var bitDepth: Int64 = 0
    var colorType: Int64 = 0
    var interlace: Int64 = 0
    var palette = Array<Byte>()
    var transparency = Array<Byte>()
    var idat = Array<Byte>()
}

private func readHeaderChunks(bytes: Array<Byte>): SvgPngHeader {
    if (bytes.size < 8) {
        throw SvgException("PNG 长度不足签名", kind: SvgErrorKind.Syntax)
    }
    let signature: Array<Byte> = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    for (index in 0..8) {
        if (bytes[index] != signature[index]) {
            throw SvgException("PNG 签名不匹配", kind: SvgErrorKind.Syntax)
        }
    }
    let header = SvgPngHeader()
    let idat = ByteBuffer()
    var position: Int64 = 8
    var sawHeader = false
    var sawIdat = false
    var idatClosed = false
    var sawIend = false
    while (position + 12 <= bytes.size) {
        let length = readU32BE(bytes, position)
        if (length < 0 || length > bytes.size - position - 12) {
            throw SvgException("PNG chunk 长度越界", kind: SvgErrorKind.Syntax)
        }
        let typeOffset = position + 4
        let dataOffset = typeOffset + 4
        let crcOffset = dataOffset + length
        let expectedCrc = readU32BE(bytes, crcOffset)
        let typeBytes = bytes[typeOffset..typeOffset + 4]
        let actualCrc = SvgCrc32.update(SvgCrc32.update(0, typeBytes), bytes[dataOffset..crcOffset])
        if (expectedCrc != actualCrc) {
            throw SvgException("PNG chunk CRC 不匹配", kind: SvgErrorKind.Syntax)
        }
        let data = bytes[dataOffset..crcOffset]
        let isHeader = chunkIs(typeBytes, "IHDR")
        let isIdat = chunkIs(typeBytes, "IDAT")
        let isIend = chunkIs(typeBytes, "IEND")
        if (!sawHeader && !isHeader) {
            throw SvgException("PNG 首个 chunk 必须是 IHDR", kind: SvgErrorKind.Syntax)
        }
        if (isHeader) {
            if (sawHeader || length != 13) {
                throw SvgException("PNG IHDR 重复或长度非法", kind: SvgErrorKind.Syntax)
            }
            header.width = readU32BE(data, 0)
            header.height = readU32BE(data, 4)
            if (header.width <= 0 || header.height <= 0) {
                throw SvgException("PNG 宽高必须为正", kind: SvgErrorKind.Syntax)
            }
            header.bitDepth = Int64(data[8])
            header.colorType = Int64(data[9])
            if (Int64(data[10]) != 0) {
                throw SvgException("不支持的 PNG 压缩方法", kind: SvgErrorKind.InvalidValue)
            }
            if (Int64(data[11]) != 0) {
                throw SvgException("不支持的 PNG 过滤方法", kind: SvgErrorKind.InvalidValue)
            }
            header.interlace = Int64(data[12])
            if (header.interlace != 0 && header.interlace != 1) {
                throw SvgException("不支持的 PNG 交错方法", kind: SvgErrorKind.InvalidValue)
            }
            sawHeader = true
        } else if (chunkIs(typeBytes, "PLTE")) {
            if (sawIdat) {
                throw SvgException("PLTE 必须位于 IDAT 之前", kind: SvgErrorKind.Syntax)
            }
            if (data.size % 3 != 0 || data.size == 0 || data.size > 768) {
                throw SvgException("PLTE 长度非法", kind: SvgErrorKind.Syntax)
            }
            header.palette = data
        } else if (chunkIs(typeBytes, "tRNS")) {
            if (sawIdat) {
                throw SvgException("tRNS 必须位于 IDAT 之前", kind: SvgErrorKind.Syntax)
            }
            header.transparency = data
        } else if (isIdat) {
            if (idatClosed) {
                throw SvgException("IDAT chunk 不连续", kind: SvgErrorKind.Syntax)
            }
            sawIdat = true
            idat.write(data)
        } else if (isIend) {
            if (length != 0) {
                throw SvgException("IEND 长度必须为 0", kind: SvgErrorKind.Syntax)
            }
            if (!sawIdat) {
                throw SvgException("PNG 缺少 IDAT", kind: SvgErrorKind.Syntax)
            }
            sawIend = true
            break
        } else {
            if (sawIdat) {
                idatClosed = true
            }
            if (isCriticalChunk(typeBytes)) {
                throw SvgException("不支持的 PNG 关键 chunk", kind: SvgErrorKind.Syntax)
            }
        }
        position = crcOffset + 4
    }
    if (!sawHeader || !sawIdat || !sawIend) {
        throw SvgException("PNG 缺少 IHDR / IDAT / IEND", kind: SvgErrorKind.Syntax)
    }
    header.idat = idat.bytes()
    header
}

private func chunkIs(typeBytes: Array<Byte>, kind: String): Bool {
    let expected = kind.unsafeBytes()
    if (typeBytes.size != 4 || expected.size != 4) {
        return false
    }
    typeBytes[0] == expected[0] && typeBytes[1] == expected[1] &&
    typeBytes[2] == expected[2] && typeBytes[3] == expected[3]
}

private func isCriticalChunk(typeBytes: Array<Byte>): Bool {
    typeBytes.size == 4 && typeBytes[0] >= 0x41 && typeBytes[0] <= 0x5A
}

private func validateColorCombination(bitDepth: Int64, colorType: Int64): Unit {
    let valid = match (colorType) {
        case 0 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
        case 2 => bitDepth == 8
        case 3 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
        case 4 => bitDepth == 8
        case 6 => bitDepth == 8
        case _ => false
    }
    if (!valid) {
        throw SvgException(
            "不支持的 PNG 颜色类型 / 位深组合：${colorType} / ${bitDepth}",
            kind: SvgErrorKind.InvalidValue
        )
    }
}

private func channelCount(colorType: Int64): Int64 {
    match (colorType) {
        case 0 => 1
        case 2 => 3
        case 3 => 1
        case 4 => 2
        case 6 => 4
        case _ => 1
    }
}

/** zlib 解压：跳过 2 字节头，校验 Adler-32，输出长度必须精确等于预期。 */
private func inflateZlib(compressed: Array<Byte>, expected: Int64): Array<Byte> {
    if (compressed.size < 6) {
        throw SvgException("zlib 数据过短", kind: SvgErrorKind.Syntax)
    }
    let cmf = Int64(compressed[0])
    let flg = Int64(compressed[1])
    if ((cmf & 0x0F) != 8 || (cmf * 256 + flg) % 31 != 0) {
        throw SvgException("zlib 头非法", kind: SvgErrorKind.Syntax)
    }
    if ((flg & 0x20) != 0) {
        throw SvgException("不支持带预置字典的 zlib 数据", kind: SvgErrorKind.InvalidValue)
    }
    let payload = compressed[2..compressed.size - 4]
    let output = ByteBuffer()
    let chunk = Array<Byte>(8192, repeat: 0)
    var produced: Int64 = 0
    try {
        let stream = DecompressInputStream(ByteBuffer(payload), wrap: WrapType.DeflateFormat, bufLen: 8192)
        var count = stream.read(chunk)
        while (count > 0) {
            if (produced + count > expected) {
                throw SvgException("PNG 解压数据超出行数上限", kind: SvgErrorKind.Syntax)
            }
            output.write(chunk[0..count])
            produced += count
            count = stream.read(chunk)
        }
    } catch (error: ZlibException) {
        throw SvgException("PNG IDAT 解压失败：${error.message}", kind: SvgErrorKind.Syntax)
    }
    let decoded = output.bytes()
    if (Int64(decoded.size) != expected) {
        throw SvgException("PNG 解压长度不符", kind: SvgErrorKind.Syntax)
    }
    let expectedAdler = readU32BE(compressed, compressed.size - 4)
    if (adler32(decoded) != expectedAdler) {
        throw SvgException("PNG Adler-32 校验失败", kind: SvgErrorKind.Syntax)
    }
    decoded
}

private func reverseFilter(
    encoded: Array<Byte>,
    previous: Array<Byte>,
    filter: Int64,
    bpp: Int64
): Array<Byte> {
    if (filter < 0 || filter > 4) {
        throw SvgException("不支持的 PNG 行 filter ${filter}", kind: SvgErrorKind.InvalidValue)
    }
    let out = Array<Byte>(encoded.size, repeat: 0)
    for (index in 0..encoded.size) {
        let left = if (index >= bpp) {
            Int64(out[index - bpp])
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
            case 4 => paeth(left, up, upLeft)
            case _ => 0
        }
        out[index] = UInt8((Int64(encoded[index]) + predicted) % 256)
    }
    out
}

private func paeth(left: Int64, up: Int64, upLeft: Int64): Int64 {
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

/**
 * 把一行（已反 filter）还原成 RGBA8。
 *
 * `x0` / `y0` / `stepX` / `stepY` 描述该行在最终位图中的位置（Adam7 各 pass）。
 */
private func writeScanline(
    bitmap: SvgBitmap,
    row: Array<Byte>,
    rowWidth: Int64,
    bitDepth: Int64,
    colorType: Int64,
    palette: Array<Byte>,
    transparency: Array<Byte>,
    x0: Int64,
    y0: Int64,
    stepX: Int64,
    stepY: Int64,
    rowIndex: Int64
): Unit {
    let channels = channelCount(colorType)
    let bitsPerPixel = channels * bitDepth
    var column = 0
    while (column < rowWidth) {
        let color = readPixel(row, column, bitsPerPixel, bitDepth, colorType, palette, transparency)
        let x = x0 + column * stepX
        let y = y0 + rowIndex * stepY
        let base = (y * bitmap.width + x) * 4
        bitmap.pixels[base] = color[0]
        bitmap.pixels[base + 1] = color[1]
        bitmap.pixels[base + 2] = color[2]
        bitmap.pixels[base + 3] = color[3]
        column++
    }
}

private func readPixel(
    row: Array<Byte>,
    column: Int64,
    bitsPerPixel: Int64,
    bitDepth: Int64,
    colorType: Int64,
    palette: Array<Byte>,
    transparency: Array<Byte>
): Array<Byte> {
    let sampleOffset = column * bitsPerPixel
    let color = Array<Byte>(4, repeat: 0)
    match (colorType) {
        case 0 =>
            let value = readSample(row, sampleOffset, bitDepth)
            let gray = scaleSample(value, bitDepth)
            let alpha = if (transparency.size >= 2 &&
                value == (Int64(transparency[0]) << 8 | Int64(transparency[1]))) {
                0
            } else {
                255
            }
            color[0] = gray
            color[1] = gray
            color[2] = gray
            color[3] = UInt8(alpha)
        case 2 =>
            let red = Int64(readSample(row, sampleOffset, 8))
            let green = Int64(readSample(row, sampleOffset + 8, 8))
            let blue = Int64(readSample(row, sampleOffset + 16, 8))
            let alpha = if (transparency.size >= 6 &&
                red == (Int64(transparency[0]) << 8 | Int64(transparency[1])) &&
                green == (Int64(transparency[2]) << 8 | Int64(transparency[3])) &&
                blue == (Int64(transparency[4]) << 8 | Int64(transparency[5]))) {
                0
            } else {
                255
            }
            color[0] = UInt8(red)
            color[1] = UInt8(green)
            color[2] = UInt8(blue)
            color[3] = UInt8(alpha)
        case 3 =>
            let index = readSample(row, sampleOffset, bitDepth)
            if (index * 3 + 2 >= palette.size) {
                throw SvgException("调色板索引越界：${index}", kind: SvgErrorKind.Syntax)
            }
            color[0] = palette[index * 3]
            color[1] = palette[index * 3 + 1]
            color[2] = palette[index * 3 + 2]
            color[3] = if (index < transparency.size) {
                transparency[index]
            } else {
                255
            }
        case 4 =>
            let gray = UInt8(readSample(row, sampleOffset, 8))
            color[0] = gray
            color[1] = gray
            color[2] = gray
            color[3] = UInt8(readSample(row, sampleOffset + 8, 8))
        case 6 =>
            color[0] = UInt8(readSample(row, sampleOffset, 8))
            color[1] = UInt8(readSample(row, sampleOffset + 8, 8))
            color[2] = UInt8(readSample(row, sampleOffset + 16, 8))
            color[3] = UInt8(readSample(row, sampleOffset + 24, 8))
        case _ => ()
    }
    color
}

/** 按位读取样本；位深 8 直接取字节，1/2/4-bit 按 MSB-first 展开。 */
private func readSample(row: Array<Byte>, bitOffset: Int64, bitDepth: Int64): Int64 {
    if (bitDepth == 8) {
        return Int64(row[bitOffset / 8])
    }
    let byteIndex = bitOffset / 8
    let shift = 8 - bitDepth - (bitOffset % 8)
    let mask = (1 << bitDepth) - 1
    (Int64(row[byteIndex]) >> shift) & mask
}

private func scaleSample(value: Int64, bitDepth: Int64): UInt8 {
    if (bitDepth == 8) {
        return UInt8(value)
    }
    let maximum = (1 << bitDepth) - 1
    UInt8((value * 255 + maximum / 2) / maximum)
}

private func readU32BE(bytes: Array<Byte>, offset: Int64): Int64 {
    (Int64(bytes[offset]) << 24) | (Int64(bytes[offset + 1]) << 16) |
    (Int64(bytes[offset + 2]) << 8) | Int64(bytes[offset + 3])
}

private func adler32(data: Array<Byte>): Int64 {
    var first: Int64 = 1
    var second: Int64 = 0
    for (byte in data) {
        first = (first + Int64(byte)) % 65521
        second = (second + first) % 65521
    }
    second * 65536 + first
}
