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
import fountain::f_base.*

/** TTF 表目录项数上限。 */
internal let SVG_TTF_MAX_TABLES: Int64 = 64
/** 单个 TTF 表长度上限（16 MiB）。 */
internal let SVG_TTF_MAX_TABLE_BYTES: Int64 = 16 * 1024 * 1024

/** 一个 sfnt 表目录项。 */
internal struct SvgTtfTable {
    let tag: String
    let offset: Int64
    let length: Int64

    init(tag: String, offset: Int64, length: Int64) {
        this.tag = tag
        this.offset = offset
        this.length = length
    }
}

/** 读取 1 字节；越界抛 Syntax。 */
internal func readTtfU8(bytes: Array<Byte>, offset: Int64): Int64 {    if (offset < 0 || offset >= Int64(bytes.size)) {
        throw SvgException("TTF 数据在偏移 ${offset} 处截断", kind: SvgErrorKind.Syntax)
    }
    Int64(bytes[offset])
}

internal func readTtfU16(bytes: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0 || offset + 2 > Int64(bytes.size)) {
        throw SvgException("TTF 数据在偏移 ${offset} 处截断", kind: SvgErrorKind.Syntax)
    }
    Int64(bytes[offset]) * 256 + Int64(bytes[offset + 1])
}

internal func readTtfI16(bytes: Array<Byte>, offset: Int64): Int64 {
    let value = readTtfU16(bytes, offset)
    if (value >= 32768) {
        value - 65536
    } else {
        value
    }
}

internal func readTtfU32(bytes: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0 || offset + 4 > Int64(bytes.size)) {
        throw SvgException("TTF 数据在偏移 ${offset} 处截断", kind: SvgErrorKind.Syntax)
    }
    Int64(bytes[offset]) * 16777216 + Int64(bytes[offset + 1]) * 65536 +
        Int64(bytes[offset + 2]) * 256 + Int64(bytes[offset + 3])
}

/**
 * 以单个 sfnt 表为边界的读取器。
 *
 * 所有偏移都是相对表起点；任何越界都抛 `SvgException(kind: Syntax)`，
 * 防止恶意长度字段把读取带到相邻表。
 */
internal class SvgTtfTableReader {
    let data: Array<Byte>
    let table: SvgTtfTable

    init(data: Array<Byte>, table: SvgTtfTable) {
        this.data = data
        this.table = table
    }

    prop length: Int64 {
        get() {
            this.table.length
        }
    }

    func require(offset: Int64, size: Int64): Unit {
        if (offset < 0 || size < 0 || offset + size > this.table.length) {
            throw SvgException(
                "TTF 表「${this.table.tag}」在偏移 ${offset} 处截断",
                kind: SvgErrorKind.Syntax
            )
        }
    }

    func u8(offset: Int64): Int64 {
        this.require(offset, 1)
        readTtfU8(this.data, this.table.offset + offset)
    }

    func u16(offset: Int64): Int64 {
        this.require(offset, 2)
        readTtfU16(this.data, this.table.offset + offset)
    }

    func i16(offset: Int64): Int64 {
        let value = this.u16(offset)
        if (value >= 32768) {
            value - 65536
        } else {
            value
        }
    }

    func i8(offset: Int64): Int64 {
        let value = this.u8(offset)
        if (value >= 128) {
            value - 256
        } else {
            value
        }
    }

    func u32(offset: Int64): Int64 {
        this.require(offset, 4)
        readTtfU32(this.data, this.table.offset + offset)
    }

    /** 派生子区间读取器；基址与长度都相对当前表。 */
    func slice(offset: Int64, length: Int64): SvgTtfTableReader {
        this.require(offset, length)
        SvgTtfTableReader(
            this.data,
            SvgTtfTable(this.table.tag, this.table.offset + offset, length)
        )
    }
}

/** 读取 4 字节表 tag；只接受可打印 ASCII，避免非法 UTF-8 抛非 SvgException。 */
private func readTtfTag(bytes: Array<Byte>, offset: Int64): String {
    var value = ""
    var index = offset
    while (index < offset + 4) {
        let byte = Int64(bytes[index])
        if (byte < 0x20 || byte > 0x7E) {
            throw SvgException("TTF 表 tag 含非法字节 ${byte}", kind: SvgErrorKind.Syntax)
        }
        value += String.fromUtf8([UInt8(byte)])
        index++
    }
    value
}

/** sfnt 表目录；所有偏移在读表体前完成校验。 */
internal class SvgTtfTableDirectory {
    private let tables: HashMap<String, SvgTtfTable>
    private let tableCount: Int64

    private init(tables: HashMap<String, SvgTtfTable>, tableCount: Int64) {
        this.tables = tables
        this.tableCount = tableCount
    }

    public prop size: Int64 {
        get() {
            this.tableCount
        }
    }

    public func table(tag: String): ?SvgTtfTable {
        this.tables.get(tag)
    }

    public static func parse(bytes: Array<Byte>): SvgTtfTableDirectory {
        if (Int64(bytes.size) < 12) {
            throw SvgException("TTF 文件头不完整", kind: SvgErrorKind.Syntax)
        }
        let version = readTtfU32(bytes, 0)
        if (version == 0x4F54544F) {
            throw SvgException("不支持 CFF / OTF 轮廓", kind: SvgErrorKind.Unsupported)
        }
        if (version != 0x00010000 && version != 0x74727565) {
            throw SvgException("未知的 sfnt 版本 ${version}", kind: SvgErrorKind.Syntax)
        }
        let numTables = readTtfU16(bytes, 4)
        if (numTables > SVG_TTF_MAX_TABLES) {
            throw SvgException(
                "TTF 表数 ${numTables} 超过上限 ${SVG_TTF_MAX_TABLES}",
                kind: SvgErrorKind.Limit
            )
        }
        if (12 + numTables * 16 > Int64(bytes.size)) {
            throw SvgException("TTF 表目录截断", kind: SvgErrorKind.Syntax)
        }
        let tables = HashMap<String, SvgTtfTable>()
        var index: Int64 = 0
        while (index < numTables) {
            let entry = 12 + index * 16
            let tag = readTtfTag(bytes, entry)
            let offset = readTtfU32(bytes, entry + 8)
            let length = readTtfU32(bytes, entry + 12)
            if (length > SVG_TTF_MAX_TABLE_BYTES) {
                throw SvgException(
                    "TTF 表「${tag}」长度 ${length} 超过上限 ${SVG_TTF_MAX_TABLE_BYTES}",
                    kind: SvgErrorKind.Limit
                )
            }
            if (offset < 0 || length < 0 || offset + length > Int64(bytes.size)) {
                throw SvgException("TTF 表「${tag}」越界", kind: SvgErrorKind.Syntax)
            }
            tables[tag] = SvgTtfTable(tag, offset, length)
            index++
        }
        SvgTtfTableDirectory(tables, numTables)
    }
}
