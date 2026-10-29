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
package fountain::f_zip

import std.collection.ArrayList
import std.io.ByteBuffer
import stdx.compress.zlib.{CompressOutputStream, WrapType}
import fountain::f_util.crc32

/**
 * 手搓 ZIP 字节的构造器：用来造"外部工具才能产出"的样本
 * （同名条目、不支持的压缩方法、加密位、CRC 不符、local header 大小为 0 等）。
 */
internal class RawEntrySpec {
    public var name: String = ""
    public var nameBytes: Array<Byte> = Array<Byte>()
    public var flags: UInt16 = 0
    public var method: UInt16 = 0
    public var crc: UInt32 = 0
    /** 已经"压缩"好的数据，原样写进 local header 之后。 */
    public var payload: Array<Byte> = Array<Byte>()
    public var uncompressedSize: Int64 = 0
    public var externalAttributes: UInt32 = 0
    /** 覆盖 local header 里的 compressed size（模拟 bit 3 置位时写 0）。 */
    public var localCompressedSize: Option<Int64> = None<Int64>
    /** 覆盖 local header 里的 uncompressed size。 */
    public var localUncompressedSize: Option<Int64> = None<Int64>
    /** 覆盖 extra 字节。 */
    public var extra: Array<Byte> = Array<Byte>()

    public init(name: String, payload: Array<Byte>) {
        this.name = name
        this.nameBytes = name.toArray()
        this.payload = payload
        this.uncompressedSize = payload.size
        this.crc = crc32(payload)
    }
}

internal func buildRawZip(entries: Array<RawEntrySpec>, comment!: Array<Byte> = Array<Byte>()): Array<Byte> {
    let out = ByteBuffer()
    let offsets = ArrayList<Int64>()
    let compressedSizes = ArrayList<Int64>()
    for (e in entries) {
        offsets.add(Int64(out.bytes().size))
        let compSize = e.localCompressedSize ?? e.payload.size
        let uncompSize = e.localUncompressedSize ?? e.uncompressedSize
        writeU32LE(out, ZipLayout.SIGNATURE_LOCAL)
        writeU16LE(out, 20)
        writeU16LE(out, e.flags)
        writeU16LE(out, e.method)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU32LE(out, e.crc)
        writeU32LE(out, UInt32(compSize))
        writeU32LE(out, UInt32(uncompSize))
        writeU16LE(out, UInt16(e.nameBytes.size))
        writeU16LE(out, UInt16(e.extra.size))
        out.write(e.nameBytes)
        out.write(e.extra)
        out.write(e.payload)
        compressedSizes.add(Int64(e.payload.size))
    }

    let cdStart = Int64(out.bytes().size)
    var i: Int64 = 0
    for (e in entries) {
        writeU32LE(out, ZipLayout.SIGNATURE_CENTRAL)
        writeU16LE(out, ZipLayout.VERSION_MADE_BY_UNIX)
        writeU16LE(out, 20)
        writeU16LE(out, e.flags)
        writeU16LE(out, e.method)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU32LE(out, e.crc)
        writeU32LE(out, UInt32(compressedSizes[i]))
        writeU32LE(out, UInt32(e.uncompressedSize))
        writeU16LE(out, UInt16(e.nameBytes.size))
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU32LE(out, e.externalAttributes)
        writeU32LE(out, UInt32(offsets[i]))
        out.write(e.nameBytes)
        i += 1
    }
    let cdSize = Int64(out.bytes().size) - cdStart

    writeU32LE(out, ZipLayout.SIGNATURE_EOCD)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, UInt16(entries.size))
    writeU16LE(out, UInt16(entries.size))
    writeU32LE(out, UInt32(cdSize))
    writeU32LE(out, UInt32(cdStart))
    writeU16LE(out, UInt16(comment.size))
    out.write(comment)
    out.bytes()
}

/** 用 `deflate` 压缩一段数据，供手工样本使用。 */
internal func deflateBytes(data: Array<Byte>): Array<Byte> {
    let buf = ByteBuffer()
    let compressor = CompressOutputStream(buf, wrap: WrapType.DeflateFormat)
    compressor.write(data)
    compressor.close()
    buf.bytes()
}
