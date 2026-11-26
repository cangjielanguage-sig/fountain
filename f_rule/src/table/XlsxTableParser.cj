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
import std.fs.Path
import fountain::f_excel.{CellRef, CellValue, ExcelDocument, ExcelSheetStream, RowData, RowReader,
    Worksheet, columnLetters}
import fountain::f_log.LoggerFactory
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.FieldType

/** `_meta` 隐藏 sheet 的固定名字（`doc/07` §6.1）。 */
let XLSX_META_SHEET = "_meta"

/**
 * 单元格渲染结果（`doc/07` §6.3）。
 *
 * [text] 是交给 `DecisionTable` 的文本形式，[kind] 是载体自身声明的类型；
 * `kind = None` 表示空单元格。
 */
class RenderedCell {
    let text: ?String
    let kind: ?FieldType

    init(text: ?String, kind: ?FieldType) {
        this.text = text
        this.kind = kind
    }

    static func empty(): RenderedCell {
        RenderedCell(None, None)
    }
}

/**
 * XLSX 决策表解析（`doc/07-decision-table.md` §6）。
 *
 * 只经由 `fountain::f_excel` 读取：`ExcelDocument` 走整表路径，
 * `ExcelSheetStream` 走流式路径（大表，内存与行数无关）。
 *
 * 结构：sheet 名即表 id；第 1 行表头；第 2 行是可选的类型行（每个非空单元格都是
 * `number/text/bool/time/list` 之一才算）；第 3 行（或第 2 行）起数据；`_meta`
 * sheet 以 key/value 两列承载表属性。
 */
public class XlsxTableParser {
    static let log = LoggerFactory.getLogger<XlsxTableParser>()

    private init() {}

    /** 工作簿内全部决策表（跳过 `_meta` 与整行空白的 sheet）。 */
    public static func parse(path: Path): Array<DecisionTable> {
        let doc = openDocument(path)
        let meta = XlsxTableParser.readMeta(doc)
        let out = ArrayList<DecisionTable>()
        for (worksheet in doc.sheets()) {
            if (worksheet.name == XLSX_META_SHEET) {
                continue
            }
            if (XlsxTableParser.headerWidth(worksheet) == 0) {
                continue
            }
            out.add(XlsxTableParser.parseWorksheet(worksheet, meta))
        }
        out.toArray()
    }

    /** 指定 sheet 的决策表；sheet 不存在（或指向 `_meta`）抛 `TABLE_INVALID`。 */
    public static func parse(path: Path, sheet: String): DecisionTable {
        if (sheet == XLSX_META_SHEET) {
            throw RuleException(RuleErrorCode.TABLE_INVALID, "_meta 是表属性 sheet，不是决策表")
        }
        let doc = openDocument(path)
        let meta = XlsxTableParser.readMeta(doc)
        let worksheet = match (doc.sheet(sheet)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "工作簿 ${path} 中没有名为 ${sheet} 的 sheet"
                )
        }
        parseWorksheet(worksheet, meta)
    }

    /**
     * 流式逐表迭代；数据行按需读取，不回写 `DecisionTable.rows`。
     *
     * 表头与类型行在建表时读一次（读完即关），数据行由 `TableRowSource` 每次迭代
     * 现开一个 `RowReader` 现取——10 万行的表也只有一行在内存里。
     */
    public static func stream(path: Path): Iterator<DecisionTable> {
        let stream = try {
            ExcelSheetStream.open(path)
        } catch (e: RuleException) {
            throw e
        } catch (e: Exception) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "无法流式读取 XLSX 决策表文件 ${path}: ${e.message}"
            )
        }
        let meta = XlsxTableParser.readStreamMeta(stream)
        XlsxTableStream(stream, stream.sheetNames(), meta)
    }

    /** 流式读 `_meta`（key/value 两列）。 */
    private static func readStreamMeta(stream: ExcelSheetStream): HashMap<String, String> {
        let meta = HashMap<String, String>()
        let reader = match (stream.rows(XLSX_META_SHEET)) {
            case Some(found) => found
            case None => return meta
        }
        var done = false
        while (!done) {
            match (reader.next()) {
                case None => done = true
                case Some(data) =>
                    XlsxTableParser.putMeta(meta, XlsxTableParser.streamCellText(data, 1),
                        XlsxTableParser.streamCellText(data, 2))
            }
        }
        reader.close()
        meta
    }

    /** 流式行里第 [col] 列的文本；缺失单元格返回空串。 */
    static func streamCellText(data: RowData, col: Int64): String {
        for (cell in data.cells) {
            if (cell.col == col) {
                match (XlsxTableParser.render(cell.value, "", data.index, col).text) {
                    case Some(text) => return text
                    case None => return ""
                }
            }
        }
        ""
    }

    /** 建表所需的表头布局；sheet 没有表头行时返回 `None`。 */
    private static func streamLayout(stream: ExcelSheetStream, sheet: String): ?XlsxStreamLayout {
        let reader = match (stream.rows(sheet)) {
            case Some(found) => found
            case None => return None<XlsxStreamLayout>
        }
        var header: Option<RowData> = None
        var typeRow: Option<RowData> = None
        var done = false
        while (!done) {
            match (reader.next()) {
                case None => done = true
                case Some(data) =>
                    if (data.index == 1) {
                        header = Some(data)
                    } else if (data.index >= 2) {
                        if (data.index == 2) {
                            typeRow = Some(data)
                        }
                        done = true
                    }
            }
        }
        reader.close()
        let first = match (header) {
            case Some(found) => found
            case None => return None<XlsxStreamLayout>
        }
        var width: Int64 = 0
        var open = true
        while (open) {
            if (XlsxTableParser.streamCellText(first, width + 1).trimAscii() == "") {
                open = false
            } else {
                width += 1
            }
        }
        if (width == 0) {
            return None<XlsxStreamLayout>
        }
        let headers = ArrayList<String>()
        var col: Int64 = 0
        while (col < width) {
            headers.add(XlsxTableParser.streamCellText(first, col + 1))
            col += 1
        }
        let texts = ArrayList<String>()
        col = 0
        while (col < width) {
            let text = match (typeRow) {
                case Some(data) =>
                    XlsxTableParser.streamCellText(data, col + 1).trimAscii().toAsciiLower()
                case None => ""
            }
            texts.add(text)
            col += 1
        }
        let types = XlsxTableParser.resolveTypeRow(texts.toArray())
        let firstDataRow = match (types) {
            case Some(_) => 3
            case None => 2
        }
        var idIndex: Int64 = -1
        col = 0
        for (text in headers.toArray()) {
            if (text.trimAscii().toAsciiLower() == "id") {
                idIndex = col
            }
            col += 1
        }
        Some(XlsxStreamLayout(headers.toArray(), types, width, firstDataRow, idIndex))
    }

    /** 流式建表：只读表头与类型行，数据行走 `XlsxRowSource`。 */
    static func streamTable(stream: ExcelSheetStream, sheet: String,
        meta: HashMap<String, String>): ?DecisionTable {
        let layout = match (streamLayout(stream, sheet)) {
            case Some(found) => found
            case None => return None<DecisionTable>
        }
        let builder = DecisionTable.builder(sheet)
        XlsxTableParser.applyMeta(builder, meta, sheet)
        for (header in layout.headers) {
            builder.column(header)
        }
        match (layout.types) {
            case Some(types) =>
                var col: Int64 = 0
                for (kind in types) {
                    match (kind) {
                        case Some(found) => builder.columnType(col, found)
                        case None => ()
                    }
                    col += 1
                }
            case None => ()
        }
        builder.rowSource(
            XlsxRowSource(stream, sheet, layout.width, layout.firstDataRow, layout.idIndex))
        Some(builder.build())
    }

    /** 读取工作簿；格式问题统一折算为 `TABLE_INVALID`。 */
    private static func openDocument(path: Path): ExcelDocument {
        try {
            ExcelDocument(path)
        } catch (e: RuleException) {
            throw e
        } catch (e: Exception) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "无法读取 XLSX 决策表文件 ${path}: ${e.message}"
            )
        }
    }

    /** `_meta` sheet → 小写 key 的属性表；缺省返回空表。 */
    private static func readMeta(doc: ExcelDocument): HashMap<String, String> {
        let meta = HashMap<String, String>()
        let worksheet = match (doc.sheet(XLSX_META_SHEET)) {
            case Some(found) => found
            case None => return meta
        }
        let rows = worksheet.rowCount()
        var row: Int64 = 1
        while (row <= rows) {
            XlsxTableParser.putMeta(meta, XlsxTableParser.cellText(worksheet, row, 1),
                XlsxTableParser.cellText(worksheet, row, 2))
            row += 1
        }
        meta
    }

    /** 写入一条表属性；空行与 `key`/`value` 表头行忽略，key 统一小写。 */
    private static func putMeta(meta: HashMap<String, String>, key: String, value: String): Unit {
        let trimmedKey = key.trimAscii()
        let trimmedValue = value.trimAscii()
        if (trimmedKey == "" || trimmedValue == "") {
            return
        }
        let lower = trimmedKey.toAsciiLower()
        if (lower == "key") {
            return
        }
        meta[lower] = trimmedValue
    }

    /** 表头宽度：第 1 行从 A 列起连续的单元格数，遇到第一个空单元格为止。 */
    private static func headerWidth(worksheet: Worksheet): Int64 {
        let cols = worksheet.colCount()
        var width: Int64 = 0
        while (width < cols) {
            if (XlsxTableParser.cellText(worksheet, 1, width + 1).trimAscii() == "") {
                break
            }
            width += 1
        }
        width
    }

    private static func cellText(worksheet: Worksheet, row: Int64, col: Int64): String {
        match (worksheet.cell(row, col)) {
            case Some(value) => match (XlsxTableParser.render(value, worksheet.name, row, col).text) {
                case Some(text) => text
                case None => ""
            }
            case None => ""
        }
    }

    private static func parseWorksheet(worksheet: Worksheet,
        meta: HashMap<String, String>): DecisionTable {
        let tableId = worksheet.name
        let width = XlsxTableParser.headerWidth(worksheet)
        if (width == 0) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "sheet ${tableId} 缺少表头行（第 1 行）"
            )
        }
        let builder = DecisionTable.builder(tableId)
        XlsxTableParser.applyMeta(builder, meta, tableId)
        var index: Int64 = 0
        while (index < width) {
            let header = XlsxTableParser.cellText(worksheet, 1, index + 1)
            builder.column(header)
            index += 1
        }
        let typeRow = XlsxTableParser.readTypeRow(worksheet, width)
        let firstDataRow = match (typeRow) {
            case Some(_) => 3
            case None => 2
        }
        // 类型行显式声明的列优先；声明为空的列仍按单元格推断
        let declared = Array<Bool>(width, repeat: false)
        match (typeRow) {
            case Some(types) =>
                var col: Int64 = 0
                for (kind in types) {
                    match (kind) {
                        case Some(found) =>
                            builder.columnType(col, found)
                            declared[col] = true
                        case None => ()
                    }
                    col += 1
                }
            case None => ()
        }
        let idIndex = XlsxTableParser.idIndex(worksheet, width)
        let merges = XlsxMergeMap(worksheet)
        let inferred = ColumnKindInference(width)
        let rowCount = worksheet.rowCount()
        var row: Int64 = firstDataRow
        while (row <= rowCount) {
            let cells = XlsxTableParser.readCells(worksheet, row, width, merges)
            var blank = true
            for (cell in cells) {
                if (cell.text.isSome()) {
                    blank = false
                    break
                }
            }
            if (!blank) {
                let values = ArrayList<?String>()
                var col: Int64 = 0
                for (cell in cells) {
                    values.add(cell.text)
                    inferred.observe(col, cell.kind)
                    col += 1
                }
                builder.rowAt(row, XlsxTableParser.ruleIdAt(cells, idIndex), values.toArray())
            }
            row += 1
        }
        // 类型行没有声明的列按单元格推断；声明过的列保持声明值（类型行覆盖推断）
        var col: Int64 = 0
        while (col < width) {
            if (!declared[col]) {
                match (inferred.result(col)) {
                    case Some(kind) => builder.columnType(col, kind)
                    case None => ()
                }
            }
            col += 1
        }
        builder.build()
    }

    /** 第 2 行是类型行时返回逐列类型，否则 `None`（此时第 2 行是数据行）。 */
    private static func readTypeRow(worksheet: Worksheet, width: Int64): Option<Array<?FieldType>> {
        let texts = ArrayList<String>()
        var col: Int64 = 0
        while (col < width) {
            texts.add(XlsxTableParser.cellText(worksheet, 2, col + 1).trimAscii().toAsciiLower())
            col += 1
        }
        XlsxTableParser.resolveTypeRow(texts.toArray())
    }

    /** 逐列类型标记 → 类型；`tokens` 全空表示不是类型行，出现未知标记返回 `None`。 */
    private static func resolveTypeRow(tokens: Array<String>): Option<Array<?FieldType>> {
        let types = ArrayList<?FieldType>()
        var count = 0
        for (text in tokens) {
            if (text == "") {
                types.add(None<FieldType>)
                continue
            }
            match (XlsxTableParser.typeOfToken(text)) {
                case Some(kind) =>
                    types.add(Some(kind))
                    count += 1
                case None => return None<Array<?FieldType>>
            }
        }
        if (count == 0) {
            return None<Array<?FieldType>>
        }
        Some(types.toArray())
    }

    /** 类型行标记 → 字段类型；未知标记返回 `None`。 */
    private static func typeOfToken(token: String): ?FieldType {
        match (token) {
            case "number" => Some(FieldType.Number)
            case "text" => Some(FieldType.Text)
            case "bool" => Some(FieldType.`Bool`)
            case "time" => Some(FieldType.Time)
            case "list" => Some(FieldType.List)
            case _ => None<FieldType>
        }
    }

    private static func idIndex(worksheet: Worksheet, width: Int64): Int64 {
        var col: Int64 = 0
        while (col < width) {
            if (XlsxTableParser.cellText(worksheet, 1, col + 1).trimAscii().toAsciiLower() == "id") {
                return col
            }
            col += 1
        }
        -1
    }

    private static func ruleIdAt(cells: Array<RenderedCell>, idIndex: Int64): String {
        if (idIndex < 0 || idIndex >= Int64(cells.size)) {
            return ""
        }
        match (cells[idIndex].text) {
            case Some(text) => text.trimAscii()
            case None => ""
        }
    }

    /**
     * 读取一行，单元格按列序展开；缺失单元格视为空。
     *
     * 被合并区域覆盖的单元格取左上角的值（`doc/07` §6.1）；表头与类型行不展开合并，
     * 因为那两行按列定位，合并后仍需每列一个值。
     */
    private static func readCells(worksheet: Worksheet, row: Int64, width: Int64,
        merges: XlsxMergeMap): Array<RenderedCell> {
        let cells = ArrayList<RenderedCell>()
        var col: Int64 = 0
        while (col < width) {
            let (sourceRow, sourceCol) = match (merges.anchorOf(row, col + 1)) {
                case Some(anchor) => anchor
                case None => (row, col + 1)
            }
            let value = worksheet.cell(sourceRow, sourceCol)
            cells.add(match (value) {
                case Some(cell) => XlsxTableParser.render(cell, worksheet.name, row, col + 1)
                case None => RenderedCell.empty()
            })
            col += 1
        }
        cells.toArray()
    }

    private static func applyMeta(builder: DecisionTableBuilder, meta: HashMap<String, String>,
        tableId: String): Unit {
        match (meta.get("name")) {
            case Some(value) => builder.name(value)
            case None => ()
        }
        match (meta.get("version")) {
            case Some(value) => builder.version(value)
            case None => ()
        }
        match (meta.get("factspace")) {
            case Some(value) => builder.factSpace(value)
            case None => ()
        }
        match (meta.get("facttype")) {
            case Some(value) => builder.factType(value)
            case None => ()
        }
        match (meta.get("hitpolicy")) {
            case Some(value) => builder.hitPolicy(HitPolicy.parse(value))
            case None => ()
        }
        match (meta.get("salience")) {
            case Some(value) => builder.salience(XlsxTableParser.parseSalience(value, tableId))
            case None => ()
        }
        match (meta.get("outputorder")) {
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
        match (meta.get("id")) {
            case Some(value) =>
                if (value.trimAscii() != tableId) {
                    XlsxTableParser.log.warn(
                        "决策表 ${tableId}：_meta.id 为 ${value}，与 sheet 名不一致，以 sheet 名为表 id"
                    )
                }
            case None => ()
        }
    }

    private static func parseSalience(text: String, tableId: String): Int64 {
        try {
            Int64.parse(text.trimAscii())
        } catch (_: Exception) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "决策表 ${tableId} 的 _meta.salience 必须是整数: ${text}"
            )
        }
    }

    /**
     * `CellValue` 八变体 → 文本 + 载体类型（`doc/07` §6.3）。
     *
     * `Error` 与无缓存值的 `Formula` 是坏数据，抛 `TABLE_INVALID`；带缓存值的公式
     * 按缓存值处理。`TimeSpan` 按总秒数呈现——值模型里没有时长类型，秒数最接近可用的
     * 数值语义。
     */
    static func render(value: CellValue, sheet: String, row: Int64,
        col: Int64): RenderedCell {
        let at = "${sheet}!${columnLetters(col)}${row}"
        match (value) {
            case Empty => RenderedCell.empty()
            case Text(text) =>
                let trimmed = text.trimAscii()
                if (trimmed == "") {
                    RenderedCell.empty()
                } else {
                    RenderedCell(Some(text), Some(FieldType.Text))
                }
            case Number(number) =>
                RenderedCell(Some(XlsxTableParser.renderNumber(number)), Some(FieldType.Number))
            case Boolean(flag) =>
                RenderedCell(Some(if (flag) { "true" } else { "false" }), Some(FieldType.`Bool`))
            case Date(moment) =>
                RenderedCell(Some(moment.format("yyyy-MM-dd HH:mm:ss")), Some(FieldType.Time))
            case TimeSpan(span) =>
                RenderedCell(Some(span.toSeconds().toString()), Some(FieldType.Number))
            case Error(code) =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "单元格 ${at} 是错误值 ${code}，决策表不能引用错误单元格"
                )
            case Formula(source, cached) =>
                match (cached) {
                    case Some(inner) => XlsxTableParser.render(inner, sheet, row, col)
                    case None =>
                        throw RuleException(
                            RuleErrorCode.TABLE_INVALID,
                            "单元格 ${at} 是公式 =${source} 且没有缓存值；" +
                            "请先在 Excel 中重算并保存"
                        )
                }
        }
    }

    /** 整数值写成整数文本，其余保留最短可回读的十进制表示。 */
    private static func renderNumber(value: Float64): String {
        if (value == 0.0) {
            return "0"
        }
        if (value > -9_007_199_254_740_992.0 && value < 9_007_199_254_740_992.0) {
            let truncated = Int64(value)
            if (Float64(truncated) == value) {
                return truncated.toString()
            }
        }
        var precision = 1
        while (precision <= 17) {
            let candidate = value.format(".${precision}g")
            let back = try {
                Float64.parse(candidate)
            } catch (_: Exception) {
                value + 1.0
            }
            if (back == value) {
                return candidate
            }
            precision += 1
        }
        value.format(".17g")
    }

}

/**
 * 逐列类型推断：一列只出现一种非空单元格类型时取该类型，混用则不给结论。
 *
 * 类型行显式声明的列不参与推断（`doc/07` §6.3：类型行覆盖推断）。
 */
class ColumnKindInference {
    private let kinds: Array<?FieldType>
    private let mixed: Array<Bool>

    init(width: Int64) {
        kinds = Array<?FieldType>(width, repeat: None<FieldType>)
        mixed = Array<Bool>(width, repeat: false)
    }

    func observe(col: Int64, kind: ?FieldType) {
        if (col < 0 || col >= Int64(kinds.size)) {
            return
        }
        match (kind) {
            case Some(found) =>
                if (mixed[col]) {
                    return
                }
                match (kinds[col]) {
                    case Some(existing) =>
                        if (existing != found) {
                            mixed[col] = true
                        }
                    case None => kinds[col] = Some(found)
                }
            case None => ()
        }
    }

    func result(col: Int64): ?FieldType {
        if (col < 0 || col >= Int64(kinds.size) || mixed[col]) {
            return None<FieldType>
        }
        kinds[col]
    }
}

/**
 * 合并区域索引（`doc/07` §6.1）。
 *
 * 只保存区域边界，值在读取时按左上角坐标现取——这样整表路径与流式路径共用同一套
 * 「只取左上角值」的语义，也不会因为合并区域很大而复制值。
 */
class XlsxMergeMap {
    private let ranges: ArrayList<(Int64, Int64, Int64, Int64)>

    init(worksheet: Worksheet) {
        this.ranges = ArrayList<(Int64, Int64, Int64, Int64)>()
        for (text in worksheet.mergedRanges()) {
            match (CellRef.parseRange(text)) {
                case Some(bounds) =>
                    ranges.add((bounds[0].row, bounds[0].col, bounds[1].row, bounds[1].col))
                case None => ()
            }
        }
    }

    /** 单元格落在某个合并区域内时返回该区域左上角坐标，否则 `None`。 */
    func anchorOf(row: Int64, col: Int64): ?(Int64, Int64) {
        for (range in ranges) {
            if (row >= range[0] && row <= range[2] && col >= range[1] && col <= range[3]) {
                return Some((range[0], range[1]))
            }
        }
        None<(Int64, Int64)>
    }
}

/** 流式建表所需的表头布局（`doc/07` §6.1）。 */
class XlsxStreamLayout {
    let headers: Array<String>
    let types: Option<Array<?FieldType>>
    let width: Int64
    let firstDataRow: Int64
    let idIndex: Int64

    init(headers: Array<String>, types: Option<Array<?FieldType>>, width: Int64,
        firstDataRow: Int64, idIndex: Int64) {
        this.headers = headers
        this.types = types
        this.width = width
        this.firstDataRow = firstDataRow
        this.idIndex = idIndex
    }
}

/** 工作簿的流式表迭代器：逐个 sheet 建表，`_meta` 与空 sheet 跳过。 */
class XlsxTableStream <: Iterator<DecisionTable> {
    private let stream: ExcelSheetStream
    private let names: Array<String>
    private let meta: HashMap<String, String>
    private var index: Int64

    init(stream: ExcelSheetStream, names: Array<String>, meta: HashMap<String, String>) {
        this.stream = stream
        this.names = names
        this.meta = meta
        this.index = 0
    }

    public func next(): Option<DecisionTable> {
        while (index < Int64(names.size)) {
            let name = names[index]
            index += 1
            if (name == XLSX_META_SHEET) {
                continue
            }
            match (XlsxTableParser.streamTable(stream, name, meta)) {
                case Some(table) => return Some(table)
                case None => ()
            }
        }
        None<DecisionTable>
    }
}

/**
 * 流式表的行来源：每次迭代现开一个 `RowReader`。
 *
 * 合并区域只在流结束后才可得（`RowReader.mergedRanges`），因此流式路径不展开
 * 合并单元格；读到流尾发现确有合并区域时记一条 WARN。
 */
class XlsxRowSource <: TableRowSource {
    private let stream: ExcelSheetStream
    private let sheet: String
    private let width: Int64
    private let firstDataRow: Int64
    private let idIndex: Int64

    init(stream: ExcelSheetStream, sheet: String, width: Int64, firstDataRow: Int64,
        idIndex: Int64) {
        this.stream = stream
        this.sheet = sheet
        this.width = width
        this.firstDataRow = firstDataRow
        this.idIndex = idIndex
    }

    public func rows(): Iterator<TableRow> {
        match (stream.rows(sheet)) {
            case Some(reader) =>
                XlsxRowIterator(reader, sheet, width, firstDataRow, idIndex)
            case None => XlsxEmptyRowIterator()
        }
    }
}

/** 空行迭代器（sheet 已被删除等极端情况）。 */
class XlsxEmptyRowIterator <: Iterator<TableRow> {
    public func next(): Option<TableRow> {
        None<TableRow>
    }
}

/** 逐行读 XLSX sheet，跳过表头/类型行与整行空白。 */
class XlsxRowIterator <: Iterator<TableRow> {
    private let reader: RowReader
    private let sheet: String
    private let width: Int64
    private let firstDataRow: Int64
    private let idIndex: Int64
    private var mergeWarned: Bool

    init(reader: RowReader, sheet: String, width: Int64, firstDataRow: Int64, idIndex: Int64) {
        this.reader = reader
        this.sheet = sheet
        this.width = width
        this.firstDataRow = firstDataRow
        this.idIndex = idIndex
        this.mergeWarned = false
    }

    public func next(): Option<TableRow> {
        var done = false
        while (!done) {
            match (reader.next()) {
                case None =>
                    warnMergedRanges()
                    done = true
                case Some(data) => match (rowOf(data)) {
                    case Some(row) => return Some(row)
                    case None => ()
                }
            }
        }
        None<TableRow>
    }

    private func rowOf(data: RowData): ?TableRow {
        if (data.index < firstDataRow) {
            return None<TableRow>
        }
        let values = Array<?String>(width, repeat: None)
        var filled = false
        for (cell in data.cells) {
            if (cell.col < 1 || cell.col > width) {
                let text = XlsxTableParser.streamCellText(data, cell.col)
                if (text.trimAscii() != "") {
                    throw RuleException(
                        RuleErrorCode.TABLE_INVALID,
                        "sheet ${sheet} 第 ${data.index} 行第 ${cell.col} 列超出表头的 ${width} 列"
                    )
                }
                continue
            }
            let rendered = XlsxTableParser.render(cell.value, sheet, data.index, cell.col)
            values[cell.col - 1] = rendered.text
            if (rendered.text.isSome()) {
                filled = true
            }
        }
        if (!filled) {
            return None<TableRow>
        }
        var ruleId = ""
        if (idIndex >= 0) {
            match (values[idIndex]) {
                case Some(text) => ruleId = text.trimAscii()
                case None => ()
            }
        }
        Some(TableRow(data.index, values, ruleId))
    }

    private func warnMergedRanges(): Unit {
        if (mergeWarned) {
            return
        }
        mergeWarned = true
        let merges = reader.mergedRanges()
        if (!merges.isEmpty()) {
            XlsxTableParser.log.warn(
                "sheet ${sheet} 有 ${merges.size} 处合并单元格，流式路径不展开合并区域" +
                "（只用左上角单元格自身的值）；需要展开请用 XlsxTableParser.parse"
            )
        }
        reader.close()
    }
}
