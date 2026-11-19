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

import std.io.OutputStream
import fountain::f_io.ByteBuffer

/**
 * 中央目录条目。写入侧是累加器（`close()` 只消费这一张表），
 * 读取侧是解析结果。
 */
internal class CentralEntry {
    public var versionMadeBy: UInt16 = ZipLayout.VERSION_MADE_BY_UNIX
    public var versionNeeded: UInt16 = ZipLayout.VERSION_DEFAULT
    public var flags: UInt16 = 0
    public var method: UInt16 = 0
    public var dosTime: UInt16 = 0
    public var dosDate: UInt16 = 0
    public var crc: UInt32 = 0
    public var compressedSize: Int64 = 0
    public var uncompressedSize: Int64 = 0
    public var internalAttributes: UInt16 = 0
    public var externalAttributes: UInt32 = 0
    public var localHeaderOffset: Int64 = 0
    public var nameBytes: Array<Byte> = Array<Byte>()
    public var comment: Array<Byte> = Array<Byte>()

    public prop name: String {
        get() {
            decodeName(nameBytes, (flags & ZipLayout.FLAG_UTF8_NAME) != 0)
        }
    }

    public prop isDirectory: Bool {
        get() {
            nameBytes.size > 0 && nameBytes[nameBytes.size - 1] == UInt8(47)
        }
    }

    public func toZipEntry(): ZipEntry {
        ZipEntry(
            name,
            compressedSize,
            uncompressedSize,
            crc,
            method,
            isDirectory,
            decodeDosDateTime(dosTime, dosDate),
            localHeaderOffset
        )
    }
}

/** 写一条 central directory header（ZIP64 只在对应字段越界时启用）。 */
internal func writeCentralHeader(out: OutputStream, e: CentralEntry): Unit {
    let origOver = e.uncompressedSize >= ZipLayout.ZIP64_MAX_U32
    let compOver = e.compressedSize >= ZipLayout.ZIP64_MAX_U32
    let offsetOver = e.localHeaderOffset >= ZipLayout.ZIP64_MAX_U32
    let zip64 = origOver || compOver || offsetOver

    let extra = if (zip64) {
        buildZip64Extra(
            e.uncompressedSize,
            origOver,
            e.compressedSize,
            compOver,
            e.localHeaderOffset,
            offsetOver,
            0,
            false
        )
    } else {
        Array<Byte>()
    }

    writeU32LE(out, ZipLayout.SIGNATURE_CENTRAL)
    writeU16LE(out, e.versionMadeBy)
    writeU16LE(out, if (zip64) {
        ZipLayout.VERSION_ZIP64
    } else {
        e.versionNeeded
    })
    writeU16LE(out, e.flags)
    writeU16LE(out, e.method)
    writeU16LE(out, e.dosTime)
    writeU16LE(out, e.dosDate)
    writeU32LE(out, e.crc)
    writeU32LE(out, if (compOver) {
        ZipLayout.SENTINEL_U32
    } else {
        UInt32(e.compressedSize)
    })
    writeU32LE(out, if (origOver) {
        ZipLayout.SENTINEL_U32
    } else {
        UInt32(e.uncompressedSize)
    })
    writeU16LE(out, UInt16(e.nameBytes.size))
    writeU16LE(out, UInt16(extra.size))
    writeU16LE(out, UInt16(e.comment.size))
    writeU16LE(out, 0)          // disk number start
    writeU16LE(out, e.internalAttributes)
    writeU32LE(out, e.externalAttributes)
    writeU32LE(out, if (offsetOver) {
        ZipLayout.SENTINEL_U32
    } else {
        UInt32(e.localHeaderOffset)
    })
    out.write(e.nameBytes)
    out.write(extra)
    out.write(e.comment)
}

/** 从 `buf` 当前位置解出一条 central directory header。 */
internal func readCentralHeader(buf: ByteBuffer): CentralEntry {
    let sig = needValue(readU32LE(buf), "中央目录截断（缺少签名）")
    if (sig != ZipLayout.SIGNATURE_CENTRAL) {
        throw ZipException("中央目录项签名不是 0x02014b50")
    }
    let e = CentralEntry()
    e.versionMadeBy = needValue(readU16LE(buf), "中央目录截断（version made by）")
    e.versionNeeded = needValue(readU16LE(buf), "中央目录截断（version needed）")
    e.flags = needValue(readU16LE(buf), "中央目录截断（flag）")
    e.method = needValue(readU16LE(buf), "中央目录截断（method）")
    e.dosTime = needValue(readU16LE(buf), "中央目录截断（time）")
    e.dosDate = needValue(readU16LE(buf), "中央目录截断（date）")
    e.crc = needValue(readU32LE(buf), "中央目录截断（crc）")
    let compField = needValue(readU32LE(buf), "中央目录截断（compressed size）")
    let uncompField = needValue(readU32LE(buf), "中央目录截断（uncompressed size）")
    let nameLen = Int64(needValue(readU16LE(buf), "中央目录截断（name length）"))
    let extraLen = Int64(needValue(readU16LE(buf), "中央目录截断（extra length）"))
    let commentLen = Int64(needValue(readU16LE(buf), "中央目录截断（comment length）"))
    let diskStart = Int64(needValue(readU16LE(buf), "中央目录截断（disk number start）"))
    e.internalAttributes = needValue(readU16LE(buf), "中央目录截断（internal attributes）")
    e.externalAttributes = needValue(readU32LE(buf), "中央目录截断（external attributes）")
    let offsetField = needValue(readU32LE(buf), "中央目录截断（local header offset）")
    e.nameBytes = needValue(readBytes(buf, nameLen), "中央目录截断（name）")
    let extra = needValue(readBytes(buf, extraLen), "中央目录截断（extra）")
    e.comment = needValue(readBytes(buf, commentLen), "中央目录截断（comment）")

    if (diskStart != 0 && diskStart != 0xFFFF) {
        throw ZipException("不支持分卷 ZIP（条目 ${e.name} 的 disk number start = ${diskStart}）")
    }
    let zip64 = parseZip64Extra(
        extra,
        uncompField == ZipLayout.SENTINEL_U32,
        compField == ZipLayout.SENTINEL_U32,
        offsetField == ZipLayout.SENTINEL_U32,
        diskStart == 0xFFFF,
        e.name
    )
    e.uncompressedSize = if (uncompField == ZipLayout.SENTINEL_U32) {
        zip64.originalSize ?? 0
    } else {
        Int64(uncompField)
    }
    e.compressedSize = if (compField == ZipLayout.SENTINEL_U32) {
        zip64.compressedSize ?? 0
    } else {
        Int64(compField)
    }
    e.localHeaderOffset = if (offsetField == ZipLayout.SENTINEL_U32) {
        zip64.localHeaderOffset ?? 0
    } else {
        Int64(offsetField)
    }
    e
}
