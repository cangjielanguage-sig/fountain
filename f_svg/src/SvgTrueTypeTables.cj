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
internal func readTtfU8(bytes: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0 || offset >= Int64(bytes.size)) {
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
            let tag = String.fromUtf8(bytes[entry..entry + 4])
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
