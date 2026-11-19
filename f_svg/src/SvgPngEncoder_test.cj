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
import std.fs.*
import std.io.ByteBuffer
import stdx.compress.zlib.{DecompressInputStream, WrapType}
import fountain::f_base.*
import std.unittest.*
import std.unittest.testmacro.*

internal class PngChunk {
    let kind: String
    let data: Array<Byte>

    init(kind: String, data: Array<Byte>) {
        this.kind = kind
        this.data = data
    }
}

internal func parsePngChunks(bytes: Array<Byte>): ArrayList<PngChunk> {
    let chunks = ArrayList<PngChunk>()
    var offset = 8
    while (offset + 12 <= bytes.size) {
        let length = Int64(bytes[offset]) * 16777216 + Int64(bytes[offset + 1]) * 65536 +
            Int64(bytes[offset + 2]) * 256 + Int64(bytes[offset + 3])
        let kind = String.fromUtf8(bytes[offset + 4..offset + 8])
        let dataStart = offset + 8
        let dataEnd = dataStart + length
        if (dataEnd + 4 > bytes.size) {
            break
        }
        chunks.add(PngChunk(kind, bytes[dataStart..dataEnd]))
        offset = dataEnd + 4
    }
    chunks
}

internal func readU32BE(bytes: Array<Byte>, offset: Int64): Int64 {
    Int64(bytes[offset]) * 16777216 + Int64(bytes[offset + 1]) * 65536 +
    Int64(bytes[offset + 2]) * 256 + Int64(bytes[offset + 3])
}

internal func adler32(bytes: Array<Byte>): Int64 {
    var a = 1
    var b = 0
    for (byte in bytes) {
        a = (a + Int64(byte)) % 65521
        b = (b + a) % 65521
    }
    b * 65536 + a
}

internal func inflateBytes(data: Array<Byte>): Array<Byte> {
    let input = ByteBuffer(data)
    let decompressor = DecompressInputStream(input, wrap: WrapType.DeflateFormat, bufLen: 4096)
    let output = ByteBuffer()
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = decompressor.read(buffer)
        if (count <= 0) {
            break
        }
        output.write(buffer[0..count])
    }
    decompressor.close()
    output.bytes()
}

internal func rgba8Bitmap(): SvgBitmap {
    let bitmap = SvgBitmap(8, 8)
    for (y in 0..8) {
        for (x in 0..8) {
            let index = (y * 8 + x) * 4
            bitmap.pixels[index] = UInt8((x * 31 + y) % 256)
            bitmap.pixels[index + 1] = UInt8((x * 7 + y * 13) % 256)
            bitmap.pixels[index + 2] = UInt8((x * 3 + y * 29) % 256)
            bitmap.pixels[index + 3] = UInt8((x * 11 + y * 17) % 256)
        }
    }
    bitmap
}

@Test
public class SvgPngEncoder_test {
    /** 签名、chunk 顺序、IHDR 字段与 IEND 空数据。 */
    @TestCase
    public func structure(): Unit {
        let bytes = SvgPngEncoder.encode(SvgBitmap(2, 2))
        @Assert(bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47)
        @Assert(bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A)
        let chunks = parsePngChunks(bytes)
        @Assert(chunks.size == 3)
        @Assert(chunks[0].kind == "IHDR")
        @Assert(chunks[1].kind == "IDAT")
        @Assert(chunks[2].kind == "IEND")
        @Assert(chunks[0].data.size == 13)
        @Assert(readU32BE(chunks[0].data, 0) == 2)
        @Assert(readU32BE(chunks[0].data, 4) == 2)
        @Assert(chunks[0].data[8] == 8)
        @Assert(chunks[0].data[9] == 6)
        @Assert(chunks[0].data[10] == 0)
        @Assert(chunks[0].data[11] == 0)
        @Assert(chunks[0].data[12] == 0)
        @Assert(chunks[2].data.size == 0)
    }

    /** IDAT：zlib 头、Adler-32、每行 filter 0、解压长度。 */
    @TestCase
    public func idatStream(): Unit {
        let bitmap = rgba8Bitmap()
        let bytes = SvgPngEncoder.encode(bitmap)
        let chunks = parsePngChunks(bytes)
        let idat = chunks[1].data
        @Assert(idat[0] == 0x78)
        @Assert(idat[1] == 0x9C)
        let deflated = idat[2..idat.size - 4]
        let raw = inflateBytes(deflated)
        @Assert(raw.size == 8 * (1 + 8 * 4))
        @Assert(adler32(raw) == readU32BE(idat, idat.size - 4))
        for (row in 0..8) {
            @Assert(raw[row * 33] == 0)
            for (column in 0..32) {
                @Assert(raw[row * 33 + 1 + column] == bitmap.pixels[row * 32 + column])
            }
        }
    }

    /** 8×8 随机 RGBA 往返逐字节一致，半透明 alpha 保留。 */
    @TestCase
    public func roundTrip(): Unit {
        let bitmap = rgba8Bitmap()
        let bytes = SvgPngEncoder.encode(bitmap)
        let chunks = parsePngChunks(bytes)
        let idat = chunks[1].data
        let raw = inflateBytes(idat[2..idat.size - 4])
        for (row in 0..8) {
            for (column in 0..32) {
                @Assert(raw[row * 33 + 1 + column] == bitmap.pixels[row * 32 + column])
            }
        }
        @Assert(raw[8] == bitmap.pixels[7])
        @Assert(raw[8] != 255 && raw[8] != 0)
    }

    /** 两次编码一致，三种入口字节一致。 */
    @TestCase
    public func deterministicOutput(): Unit {
        let bitmap = rgba8Bitmap()
        let first = SvgPngEncoder.encode(bitmap)
        let second = SvgPngEncoder.encode(bitmap)
        @Assert(first == second)
        let buffer = ByteBuffer()
        SvgPngEncoder.write(bitmap, buffer)
        @Assert(buffer.bytes() == first)
        @Assert(bitmap.toPngBytes() == first)
    }

    /** 每个 chunk 的存储 CRC 与重新计算结果一致。 */
    @TestCase
    public func chunkChecksums(): Unit {
        let bytes = SvgPngEncoder.encode(rgba8Bitmap())
        var offset = 8
        var chunks = 0
        while (offset + 12 <= bytes.size) {
            let length = readU32BE(bytes, offset)
            let dataEnd = offset + 8 + length
            if (dataEnd + 4 > bytes.size) {
                break
            }
            let stored = readU32BE(bytes, dataEnd)
            @Assert(SvgCrc32.checksum(bytes[offset + 4..dataEnd]) == stored)
            chunks++
            offset = dataEnd + 4
        }
        @Assert(chunks == 3)
    }

    /** 文件输出：正常保存与目录不存在抛 InvalidValue。 */
    @TestCase
    public func fileOutput(): Unit {
        let bitmap = rgba8Bitmap()
        let path = Path("/tmp/f_svg_m2_png_test.png")
        bitmap.savePng(path)
        @Assert(exists(path))
        @Assert(File.readFrom(path) == bitmap.toPngBytes())

        let error = expectSvgException({=> bitmap.savePng(Path("/f_svg_no_such_dir_123/out.png"))})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
    }
}
