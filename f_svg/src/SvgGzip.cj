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

import std.io.ByteBuffer
import stdx.compress.zlib.{CompressOutputStream, DecompressInputStream, WrapType, ZlibException}

/**
 * SVGZ 的 gzip 编解码。
 *
 * 解压按块读取并在超过上限时立即抛 `Limit`；gzip 尾部 CRC 与 ISIZE 单独校验，
 * 保证截断或损坏的数据不会被静默接受。压缩固定使用 `WrapType.GzipFormat`，
 * zlib 在未设置 gz_header 时写入 mtime = 0，因此同输入输出逐字节一致。
 */
public class SvgGzip {
    /** 解压 gzip 字节；非 gzip / 截断 / CRC 不符抛 `Syntax`，超上限抛 `Limit`。 */
    public static func decompress(bytes: Array<Byte>, maxBytes!: Int64): Array<Byte> {
        if (maxBytes <= 0) {
            throw invalidValue("解压上限必须为正，实际 ${maxBytes}")
        }
        if (bytes.size < 18 || bytes[0] != 0x1F || bytes[1] != 0x8B || bytes[2] != 0x08) {
            throw SvgException("不是有效的 gzip 数据", kind: SvgErrorKind.Syntax)
        }
        let output = ByteBuffer()
        let chunk = Array<Byte>(8192, repeat: 0)
        var produced: Int64 = 0
        try {
            let stream = DecompressInputStream(ByteBuffer(bytes), wrap: WrapType.GzipFormat, bufLen: 8192)
            var count = stream.read(chunk)
            while (count > 0) {
                produced += count
                if (produced > maxBytes) {
                    throw SvgException(
                        "gzip 解压输出超过上限 ${maxBytes} 字节",
                        kind: SvgErrorKind.Limit
                    )
                }
                output.write(chunk[0..count])
                count = stream.read(chunk)
            }
        } catch (error: ZlibException) {
            throw SvgException("gzip 数据损坏：${error.message}", kind: SvgErrorKind.Syntax)
        }
        let decoded = output.bytes()
        verifyTrailer(bytes, decoded)
        decoded
    }

    /** 压缩为 gzip 字节。 */
    public static func compress(bytes: Array<Byte>): Array<Byte> {
        let output = ByteBuffer()
        let compressor = CompressOutputStream(output, wrap: WrapType.GzipFormat)
        compressor.write(bytes)
        compressor.close()
        output.bytes()
    }

    /** 校验 gzip 尾部的 CRC-32 与 ISIZE。 */
    private static func verifyTrailer(compressed: Array<Byte>, decoded: Array<Byte>): Unit {
        let base = compressed.size - 8
        let expectedCrc = readU32LE(compressed, base)
        let expectedSize = readU32LE(compressed, base + 4)
        let actualCrc = SvgCrc32.checksum(decoded)
        if (actualCrc != expectedCrc) {
            throw SvgException("gzip CRC 校验失败", kind: SvgErrorKind.Syntax)
        }
        if (Int64(decoded.size) % 4_294_967_296 != expectedSize) {
            throw SvgException("gzip 解压长度与 ISIZE 不符", kind: SvgErrorKind.Syntax)
        }
    }

    private static func readU32LE(bytes: Array<Byte>, offset: Int64): Int64 {
        Int64(bytes[offset]) | (Int64(bytes[offset + 1]) << 8) |
        (Int64(bytes[offset + 2]) << 16) | (Int64(bytes[offset + 3]) << 24)
    }
}

/** 把文档写成 gzip 压缩的 SVG 字节。 */
public func writeGzip(document: SvgDocument): Array<Byte> {
    SvgGzip.compress(writeSvgString(document).toArray())
}

// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。
