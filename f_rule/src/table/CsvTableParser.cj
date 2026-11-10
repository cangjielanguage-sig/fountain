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
package fountain::f_rule.table

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.fs.{File, Path}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/** 一条 CSV 记录；[comment] 为元数据/注释行（`#` 开头）。 */
class CsvRecord {
    let line: Int64
    let cells: Array<String>
    let comment: Bool

    init(line: Int64, cells: Array<String>, comment: Bool) {
        this.line = line
        this.cells = cells
        this.comment = comment
    }
}

/**
 * RFC 4180 状态机（`doc/07-decision-table.md` §5.2）。
 *
 * 按字节扫描：ASCII 分隔符只在引号外生效，UTF-8 内容按原字节拼回字符串。
 * 记录起始行号用于报错与 [TableRow.line]；引号内换行会让物理行号递增。
 */
class CsvScanner {
    private let bytes: Array<UInt8>
    private let start: Int64
    private var index: Int64
    private var line: Int64
    private var recordLine: Int64
    private let row: ArrayList<String>
    private let cell: ArrayList<UInt8>
    private var inQuotes: Bool
    private let records: ArrayList<CsvRecord>

    init(bytes: Array<UInt8>, start: Int64) {
        this.bytes = bytes
        this.start = start
        this.index = start
        this.line = 1
        this.recordLine = 1
        this.row = ArrayList<String>()
        this.cell = ArrayList<UInt8>()
        this.inQuotes = false
        this.records = ArrayList<CsvRecord>()
    }

    func scan(): Array<CsvRecord> {
        while (index < Int64(bytes.size)) {
            if (!inQuotes && row.isEmpty() && cell.isEmpty() && bytes[index] == b'#') {
                readComment()
                continue
            }
            let byte = bytes[index]
            if (inQuotes) {
                readQuoted(byte)
                continue
            }
            if (byte == b'"') {
                if (cell.isEmpty()) {
                    inQuotes = true
                } else {
                    cell.add(byte)
                }
                index += 1
                continue
            }
            if (byte == b',') {
                flushCell()
                index += 1
                continue
            }
            if (byte == b'\n') {
                flushRow()
                index += 1
                line += 1
                recordLine = line
                continue
            }
            if (byte == b'\r' && index + 1 < Int64(bytes.size) && bytes[index + 1] == b'\n') {
                flushRow()
                index += 2
                line += 1
                recordLine = line
                continue
            }
            cell.add(byte)
            index += 1
        }
        if (cell.size > 0 || !row.isEmpty()) {
            flushRow()
        }
        records.toArray()
    }

    private func readQuoted(byte: UInt8): Unit {
        if (byte == b'"') {
            if (index + 1 < Int64(bytes.size) && bytes[index + 1] == b'"') {
                cell.add(b'"')
                index += 2
                return
            }
            inQuotes = false
            index += 1
            return
        }
        if (byte == b'\n') {
            cell.add(b'\n')
            index += 1
            line += 1
            return
        }
        if (byte == b'\r' && index + 1 < Int64(bytes.size) && bytes[index + 1] == b'\n') {
            cell.add(b'\n')
            index += 2
            line += 1
            return
        }
        cell.add(byte)
        index += 1
    }

    private func readComment(): Unit {
        let from = index + 1
        var end = index
        while (end < Int64(bytes.size) && bytes[end] != b'\n') {
            end += 1
        }
        var textEnd = end
        if (textEnd > from && bytes[textEnd - 1] == b'\r') {
            textEnd -= 1
        }
        records.add(CsvRecord(recordLine, [String.fromUtf8(bytes[from..textEnd])], true))
        index = end
        if (index < Int64(bytes.size) && bytes[index] == b'\n') {
            index += 1
        }
        line += 1
        recordLine = line
    }

    private func flushCell(): Unit {
        row.add(String.fromUtf8(cell.toArray()))
        cell.clear()
    }

    private func flushRow(): Unit {
        flushCell()
        var blank = row.size == 1 && row[0].trimAscii() == ""
        if (!blank) {
            records.add(CsvRecord(recordLine, row.toArray(), false))
        }
        row.clear()
    }
}

/**
 * CSV 决策表解析（`doc/07-decision-table.md` §5）。
 *
 * 只接受 UTF-8；BOM 自动跳过。`# key: value` 行作为表属性，其余 `#` 行为注释。
 * 列数不一致、未知表头、缺失 `id` 均抛 `TABLE_INVALID`，错误消息带物理行号。
 */
public class CsvTableParser {
    private init() {}

    public static func parse(text: String): DecisionTable {
        parseBytes(text.toArray())
    }

    public static func parseFile(path: Path): DecisionTable {
        let bytes = File.readFrom(path)
        if (!isValidUtf8(bytes)) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "决策表文件 ${path} 不是合法的 UTF-8 编码"
            )
        }
        parseBytes(bytes)
    }

    private static func parseBytes(raw: Array<UInt8>): DecisionTable {
        var start: Int64 = 0
        if (raw.size >= 3 && raw[0] == 0xEFu8 && raw[1] == 0xBBu8 && raw[2] == 0xBFu8) {
            start = 3
        }
        let records = CsvScanner(raw, start).scan()
        let metadata = HashMap<String, String>()
        var header: ?CsvRecord = None
        let data = ArrayList<CsvRecord>()
        for (record in records) {
            if (record.comment) {
                applyMetadata(metadata, record.cells[0])
                continue
            }
            match (header) {
                case None => header = Some(record)
                case Some(_) => data.add(record)
            }
        }
        let headerRecord = match (header) {
            case Some(found) => found
            case None =>
                throw RuleException(RuleErrorCode.TABLE_INVALID, "决策表 CSV 缺少表头行")
        }
        let id = CsvTableParser.required(metadata, "id", headerRecord.line)
        let builder = DecisionTable.builder(id)
        match (metadata.get("name")) {
            case Some(value) => builder.name(value)
            case None => ()
        }
        match (metadata.get("version")) {
            case Some(value) => builder.version(value)
            case None => ()
        }
        match (metadata.get("factspace")) {
            case Some(value) => builder.factSpace(value)
            case None => ()
        }
        match (metadata.get("facttype")) {
            case Some(value) => builder.factType(value)
            case None => ()
        }
        match (metadata.get("hitpolicy")) {
            case Some(value) => builder.hitPolicy(HitPolicy.parse(value))
            case None => ()
        }
        match (metadata.get("salience")) {
            case Some(value) => builder.salience(parseSalience(value))
            case None => ()
        }
        match (metadata.get("outputorder")) {
            case Some(value) =>
                let names = ArrayList<String>()
                for (part in value.split(",")) {
                    let trimmed = part.trimAscii()
                    if (trimmed != "") {
                        names.add(trimmed)
                    }
                }
                builder.outputOrder(names.toArray())
            case None => ()
        }
        for (cell in headerRecord.cells) {
            builder.column(cell)
        }
        let idIndex = headerIndex(headerRecord.cells, "id")
        for (record in data) {
            if (record.cells.size != headerRecord.cells.size) {
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "决策表 ${id} 第 ${record.line} 行列数不一致: 期望 ${headerRecord.cells.size}，" +
                    "实际 ${record.cells.size}（line=${record.line}）"
                )
            }
            let values = ArrayList<?String>()
            for (cell in record.cells) {
                if (cell == "") {
                    values.add(None)
                } else {
                    values.add(Some(cell))
                }
            }
            var ruleId = ""
            if (idIndex >= 0) {
                ruleId = record.cells[idIndex].trimAscii()
            }
            builder.rowAt(record.line, ruleId, values.toArray())
        }
        builder.build()
    }

    private static func applyMetadata(metadata: HashMap<String, String>, text: String): Unit {
        let trimmed = text.trimAscii()
        if (trimmed == "") {
            return
        }
        match (trimmed.indexOf(":")) {
            case Some(position) =>
                let key = trimmed[0..position].trimAscii().toAsciiLower()
                let value = trimmed[position + 1..].trimAscii()
                if (key != "") {
                    metadata[key] = value
                }
            case None => ()
        }
    }

    private static func required(metadata: HashMap<String, String>, key: String,
        line: Int64): String {
        match (metadata.get(key)) {
            case Some(value) =>
                if (value.trimAscii() == "") {
                    throw RuleException(
                        RuleErrorCode.TABLE_INVALID,
                        "决策表 CSV 的 # ${key} 不能为空（line=${line}）"
                    )
                }
                value
            case None =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "决策表 CSV 缺少 # ${key} 元数据（line=${line}）"
                )
        }
    }

    private static func parseSalience(text: String): Int64 {
        try {
            Int64.parse(text.trimAscii())
        } catch (_: Exception) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "# salience 必须是整数: ${text}"
            )
        }
    }

    private static func headerIndex(cells: Array<String>, name: String): Int64 {
        var index: Int64 = 0
        for (cell in cells) {
            if (cell.trimAscii().toAsciiLower() == name) {
                return index
            }
            index += 1
        }
        -1
    }

    /** 标准 UTF-8 校验；只接受最短合法编码。 */
    static func isValidUtf8(bytes: Array<UInt8>): Bool {
        var i: Int64 = 0
        let size = Int64(bytes.size)
        while (i < size) {
            let first = bytes[i]
            if (first < 0x80u8) {
                i += 1
                continue
            }
            var extra: Int64 = 0
            if (first >= 0xC2u8 && first <= 0xDFu8) {
                extra = 1
            } else if (first >= 0xE0u8 && first <= 0xEFu8) {
                extra = 2
            } else if (first >= 0xF0u8 && first <= 0xF4u8) {
                extra = 3
            } else {
                return false
            }
            if (i + extra >= size) {
                return false
            }
            var j = i + 1
            while (j <= i + extra) {
                let next = bytes[j]
                if (next < 0x80u8 || next > 0xBFu8) {
                    return false
                }
                j += 1
            }
            // 过长编码与代理区
            if (first == 0xE0u8 && bytes[i + 1] < 0xA0u8) {
                return false
            }
            if (first == 0xEDu8 && bytes[i + 1] > 0x9Fu8) {
                return false
            }
            if (first == 0xF0u8 && bytes[i + 1] < 0x90u8) {
                return false
            }
            if (first == 0xF4u8 && bytes[i + 1] > 0x8Fu8) {
                return false
            }
            i += extra + 1
        }
        true
    }
}
