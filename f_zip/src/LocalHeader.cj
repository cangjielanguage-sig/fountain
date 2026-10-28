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
import std.io.OutputStream
import fountain::f_io.ByteBuffer

/**
 * ZIP64 extended information extra field（ID `0x0001`）。
 *
 * **extra 里只放越界的字段**，顺序固定为
 * `originalSize(8) → compressedSize(8) → localHeaderOffset(8) → diskStart(4)`。
 * 读端必须"先看 extra 总长度，再按哪些字段是哨兵值决定读几个 8 字节"，
 * 不能按字段位置硬读——长度不足时要报 `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）`。
 */
internal struct Zip64ExtraValues {
    public let originalSize: Option<Int64>
    public let compressedSize: Option<Int64>
    public let localHeaderOffset: Option<Int64>
    public let diskStart: Option<Int64>

    public init(
        originalSize: Option<Int64>,
        compressedSize: Option<Int64>,
        localHeaderOffset: Option<Int64>,
        diskStart: Option<Int64>
    ) {
        this.originalSize = originalSize
        this.compressedSize = compressedSize
        this.localHeaderOffset = localHeaderOffset
        this.diskStart = diskStart
    }

    public static func empty(): Zip64ExtraValues {
        Zip64ExtraValues(None<Int64>, None<Int64>, None<Int64>, None<Int64>)
    }
}

/**
 * 构造 ZIP64 extra（含 `0x0001` 头）；四个字段都不需要时返回空数组，
 * 也就是"不越界就不写任何 ZIP64 字节"。
 */
internal func buildZip64Extra(
    originalSize: Int64,
    hasOriginalSize: Bool,
    compressedSize: Int64,
    hasCompressedSize: Bool,
    localHeaderOffset: Int64,
    hasLocalHeaderOffset: Bool,
    diskStart: Int64,
    hasDiskStart: Bool
): Array<Byte> {
    let payload = ArrayList<Array<Byte>>()
    if (hasOriginalSize) {
        payload.add(u64LEBytes(UInt64(originalSize)))
    }
    if (hasCompressedSize) {
        payload.add(u64LEBytes(UInt64(compressedSize)))
    }
    if (hasLocalHeaderOffset) {
        payload.add(u64LEBytes(UInt64(localHeaderOffset)))
    }
    if (hasDiskStart) {
        payload.add(u32LEBytes(UInt32(diskStart)))
    }
    if (payload.isEmpty()) {
        return Array<Byte>()
    }
    let body = concatBytes(payload.toArray())
    concatBytes([u16LEBytes(ZipLayout.ZIP64_EXTRA_ID), u16LEBytes(UInt16(body.size)), body])
}

/**
 * 解析 extra 里的 `0x0001` 块。`want*` 由调用方按"哪些字段是哨兵值"给出。
 */
internal func parseZip64Extra(
    extra: Array<Byte>,
    wantOriginalSize: Bool,
    wantCompressedSize: Bool,
    wantLocalHeaderOffset: Bool,
    wantDiskStart: Bool,
    name: String
): Zip64ExtraValues {
    if (!wantOriginalSize && !wantCompressedSize && !wantLocalHeaderOffset && !wantDiskStart) {
        return Zip64ExtraValues.empty()
    }
    var pos = 0
    while (pos + 4 <= extra.size) {
        let id = u16At(extra, pos)
        let len = Int64(u16At(extra, pos + 2))
        let dataStart = pos + 4
        if (dataStart + len > extra.size) {
            break
        }
        if (id == ZipLayout.ZIP64_EXTRA_ID) {
            var need: Int64 = 0
            if (wantOriginalSize) {
                need += 8
            }
            if (wantCompressedSize) {
                need += 8
            }
            if (wantLocalHeaderOffset) {
                need += 8
            }
            if (wantDiskStart) {
                need += 4
            }
            if (len < need) {
                throw ZipException("ZIP64 extra 长度不足：需要 ${need}，实际 ${len}（${name}）")
            }
            var cursor = dataStart
            var orig = None<Int64>
            var comp = None<Int64>
            var offset = None<Int64>
            var disk = None<Int64>
            if (wantOriginalSize) {
                orig = Some(Int64(u64At(extra, cursor)))
                cursor += 8
            }
            if (wantCompressedSize) {
                comp = Some(Int64(u64At(extra, cursor)))
                cursor += 8
            }
            if (wantLocalHeaderOffset) {
                offset = Some(Int64(u64At(extra, cursor)))
                cursor += 8
            }
            if (wantDiskStart) {
                disk = Some(Int64(u32At(extra, cursor)))
            }
            return Zip64ExtraValues(orig, comp, offset, disk)
        }
        pos = dataStart + len
    }
    let need = (if (wantOriginalSize) {
        8
    } else {
        0
    }) + (if (wantCompressedSize) {
        8
    } else {
        0
    }) + (if (wantLocalHeaderOffset) {
        8
    } else {
        0
    }) + (if (wantDiskStart) {
        4
    } else {
        0
    })
    throw ZipException("ZIP64 extra 长度不足：需要 ${need}，实际 0（${name}）")
}

/**
 * Local File Header（固定 30 字节 + name + extra）。
 *
 * 两种填法：
 * - **内存路径**：真实 crc / 大小，bit 3 = 0，不写 descriptor；
 * - **流式路径**：全 0，bit 3 = 1，`version needed = 45`，extra 里放 `0x0001` 占位（两个 8 字节值都是 0）。
 */
internal class LocalHeader {
    public var versionNeeded: UInt16 = ZipLayout.VERSION_DEFAULT
    public var flags: UInt16 = 0
    public var method: UInt16 = 0
    public var dosTime: UInt16 = 0
    public var dosDate: UInt16 = 0
    public var crc: UInt32 = 0
    public var compressedSize: Int64 = 0
    public var uncompressedSize: Int64 = 0
    public var nameBytes: Array<Byte> = Array<Byte>()
    /** 流式条目：header 里全 0 + bit 3 + ZIP64 extra 占位。 */
    public var streaming: Bool = false
    /** 读取侧：数据起点（绝对偏移）。 */
    public var dataOffset: Int64 = 0
}

internal func writeLocalHeader(out: OutputStream, h: LocalHeader): Unit {
    var version = h.versionNeeded
    var flags = h.flags
    var crcField: UInt32 = h.crc
    var compField = UInt32(0)
    var uncompField = UInt32(0)
    var extra = Array<Byte>()

    if (h.streaming) {
        flags = flags | ZipLayout.FLAG_DATA_DESCRIPTOR
        version = ZipLayout.VERSION_ZIP64
        crcField = 0
        compField = 0
        uncompField = 0
        extra = buildZip64Extra(0, true, 0, true, 0, false, 0, false)
    } else {
        let origOver = h.uncompressedSize >= ZipLayout.ZIP64_MAX_U32
        let compOver = h.compressedSize >= ZipLayout.ZIP64_MAX_U32
        if (origOver || compOver) {
            version = ZipLayout.VERSION_ZIP64
            compField = if (compOver) {
                ZipLayout.SENTINEL_U32
            } else {
                UInt32(h.compressedSize)
            }
            uncompField = if (origOver) {
                ZipLayout.SENTINEL_U32
            } else {
                UInt32(h.uncompressedSize)
            }
            extra = buildZip64Extra(h.uncompressedSize, origOver, h.compressedSize, compOver, 0, false, 0, false)
        } else {
            compField = UInt32(h.compressedSize)
            uncompField = UInt32(h.uncompressedSize)
        }
    }

    writeU32LE(out, ZipLayout.SIGNATURE_LOCAL)
    writeU16LE(out, version)
    writeU16LE(out, flags)
    writeU16LE(out, h.method)
    writeU16LE(out, h.dosTime)
    writeU16LE(out, h.dosDate)
    writeU32LE(out, crcField)
    writeU32LE(out, compField)
    writeU32LE(out, uncompField)
    writeU16LE(out, UInt16(h.nameBytes.size))
    writeU16LE(out, UInt16(extra.size))
    out.write(h.nameBytes)
    out.write(extra)
}

/** 从 `buf` 当前位置解出一个 local header（含 name 与 extra）。 */
internal func readLocalHeader(buf: ByteBuffer): LocalHeader {
    let sig = needValue(readU32LE(buf), "local header 截断（缺少签名）")
    if (sig != ZipLayout.SIGNATURE_LOCAL) {
        throw ZipException("local header 签名不是 0x04034b50")
    }
    let h = LocalHeader()
    h.versionNeeded = needValue(readU16LE(buf), "local header 截断（version needed）")
    h.flags = needValue(readU16LE(buf), "local header 截断（flag）")
    h.method = needValue(readU16LE(buf), "local header 截断（method）")
    h.dosTime = needValue(readU16LE(buf), "local header 截断（time）")
    h.dosDate = needValue(readU16LE(buf), "local header 截断（date）")
    h.crc = needValue(readU32LE(buf), "local header 截断（crc）")
    let compField = needValue(readU32LE(buf), "local header 截断（compressed size）")
    let uncompField = needValue(readU32LE(buf), "local header 截断（uncompressed size）")
    let nameLen = Int64(needValue(readU16LE(buf), "local header 截断（name length）"))
    let extraLen = Int64(needValue(readU16LE(buf), "local header 截断（extra length）"))
    h.nameBytes = needValue(readBytes(buf, nameLen), "local header 截断（name）")
    let extra = needValue(readBytes(buf, extraLen), "local header 截断（extra）")
    let name = decodeName(h.nameBytes, (h.flags & ZipLayout.FLAG_UTF8_NAME) != 0)
    let zip64 = parseZip64Extra(
        extra,
        uncompField == ZipLayout.SENTINEL_U32,
        compField == ZipLayout.SENTINEL_U32,
        false,
        false,
        name
    )
    h.compressedSize = if (compField == ZipLayout.SENTINEL_U32) {
        zip64.compressedSize ?? 0
    } else {
        Int64(compField)
    }
    h.uncompressedSize = if (uncompField == ZipLayout.SENTINEL_U32) {
        zip64.originalSize ?? 0
    } else {
        Int64(uncompField)
    }
    h
}
