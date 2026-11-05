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

import std.io.{ByteBuffer, OutputStream}
import stdx.compress.zlib.{CompressOutputStream, WrapType}
import fountain::f_base.*

private let PNG_SIGNATURE: Array<Byte> = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/** 确定性 PNG 编码器：签名 + IHDR + IDAT + IEND，RGBA8，每行 filter 0。 */
public class SvgPngEncoder {
    public static func encode(bitmap: SvgBitmap): Array<Byte> {
        let output = ByteBuffer()
        write(bitmap, output)
        output.bytes()
    }

    public static func write(bitmap: SvgBitmap, output: OutputStream): Unit {
        output.write(PNG_SIGNATURE)
        let header = Array<Byte>(13, repeat: 0)
        writeU32BE(header, 0, bitmap.width)
        writeU32BE(header, 4, bitmap.height)
        header[8] = 8
        header[9] = 6
        header[10] = 0
        header[11] = 0
        header[12] = 0
        writeChunk(output, "IHDR", header)

        let raw = buildRawScanlines(bitmap)
        let deflated = deflateBytes(raw)
        let idat = ByteBuffer()
        idat.write([0x78, 0x9C])
        idat.write(deflated)
        let adler = adler32(raw)
        let adlerBytes = Array<Byte>(4, repeat: 0)
        writeU32BE(adlerBytes, 0, adler)
        idat.write(adlerBytes)
        writeChunk(output, "IDAT", idat.bytes())

        writeChunk(output, "IEND", Array<Byte>())
    }
}

private func buildRawScanlines(bitmap: SvgBitmap): Array<Byte> {
    let stride = bitmap.width * 4 + 1
    let raw = Array<Byte>(stride * bitmap.height, repeat: 0)
    var row = 0
    while (row < bitmap.height) {
        let base = row * stride
        raw[base] = 0
        for (index in 0..bitmap.width * 4) {
            raw[base + 1 + index] = bitmap.pixels[row * bitmap.width * 4 + index]
        }
        row++
    }
    raw
}

private func deflateBytes(data: Array<Byte>): Array<Byte> {
    let buffer = ByteBuffer()
    let compressor = CompressOutputStream(buffer, wrap: WrapType.DeflateFormat)
    compressor.write(data)
    compressor.close()
    buffer.bytes()
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

private func writeChunk(output: OutputStream, kind: String, data: Array<Byte>): Unit {
    writeU32BETo(output, Int64(data.size))
    let kindBytes = kind.unsafeBytes()
    output.write(kindBytes)
    output.write(data)
    let crcInput = Array<Byte>(kindBytes.size + data.size, repeat: 0)
    for (index in 0..kindBytes.size) {
        crcInput[index] = kindBytes[index]
    }
    for (index in 0..data.size) {
        crcInput[kindBytes.size + index] = data[index]
    }
    writeU32BETo(output, SvgCrc32.checksum(crcInput))
}

private func writeU32BE(target: Array<Byte>, offset: Int64, value: Int64): Unit {
    target[offset] = UInt8((value >> 24) & 0xFF)
    target[offset + 1] = UInt8((value >> 16) & 0xFF)
    target[offset + 2] = UInt8((value >> 8) & 0xFF)
    target[offset + 3] = UInt8(value & 0xFF)
}

private func writeU32BETo(output: OutputStream, value: Int64): Unit {
    let bytes = Array<Byte>(4, repeat: 0)
    writeU32BE(bytes, 0, value)
    output.write(bytes)
}
