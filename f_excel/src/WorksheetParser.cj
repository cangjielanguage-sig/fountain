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
package fountain::f_excel

import std.collection.ArrayList
import std.convert.*
import std.io.ByteBuffer
import std.time.DateTime
import fountain::f_base.StringGenerator
import fountain::f_xml.{XmlAttribute, XmlEvent, XmlPullParser}


private func parseIntOrNone(text: String): ?Int64 {
    try {
        Some(Int64.parse(text))
    } catch (_: Exception) {
        None<Int64>
    }
}

private func parseFloatOrNone(text: String): ?Float64 {
    try {
        Some(Float64.parse(text))
    } catch (_: Exception) {
        None<Float64>
    }
}

private func parseDateOrNone(text: String): ?DateTime {
    try {
        Some(DateTime.parse(text))
    } catch (_: Exception) {
        None<DateTime>
    }
}

/** 行级回调：整文档通道累加进 `Worksheet`，流式通道直接交给调用方。 */
internal interface RowSink {
    func row(data: RowData): Unit
    func merged(ranges: ArrayList<String>): Unit
}

/** 解析结果（整文档通道用）。 */
internal class ParsedSheet {
    let rows = ArrayList<RowData>()
    let merges = ArrayList<String>()
    var dimension: ?String = None
    let warnings = ArrayList<ExcelWarning>()
}

/**
 * worksheet 事件流 → [RowSink]。
 *
 * 三条通道共用：整文档、流式、以及测试里的直接解析。
 */
internal class WorksheetParser {
    static func parseSheet(
        bytes: Array<Byte>,
        options: ExcelReadOptions,
        sst: SharedStringTable,
        sheetName: String
    ): ParsedSheet {
        let parsed = ParsedSheet()
        let handler = SheetRowHandler(options, sst, sheetName, parsed)
        let parser = XmlPullParser(ByteBuffer(bytes))
        try {
            while (let Some(event) <- parser.nextEvent()) {
                handler.onEvent(event)
            }
        } finally {
            parser.close()
        }
        parsed
    }
}

/** 单张 sheet 的事件状态机。 */
internal class SheetRowHandler {
    private let options: ExcelReadOptions
    private let sst: SharedStringTable
    private let sheetName: String
    private let parsed: ParsedSheet

    private var rowActive = false
    private var skipRow = false
    private var rowIndex: Int64 = 0
    private var rowHeight: ?Float64 = None
    private var cells = ArrayList<Cell>()
    private var lastRow: Int64 = 0
    private var lastCol: Int64 = 0
    private var maxRowWarned = false
    private var maxColWarned = false

    private var cellActive = false
    private var skipCell = false
    private var col: Int64 = 0
    private var cellType: ?String = None
    private var valueText = StringGenerator()
    private var inlineText = StringGenerator()
    private var formulaText = StringGenerator()
    private var formulaType: ?String = None
    private var inValue = false
    private var inInline = false
    private var inInlineText = false
    private var inFormula = false

    init(options: ExcelReadOptions, sst: SharedStringTable, sheetName: String, parsed: ParsedSheet) {
        this.options = options
        this.sst = sst
        this.sheetName = sheetName
        this.parsed = parsed
    }

    func onEvent(event: XmlEvent): Unit {
        match (event) {
            case StartElement(name, attrs, _) => onStart(name.local, attrs)
            case EndElement(name) => onEnd(name.local)
            case Text(value) => onText(value)
            case CData(value) => onText(value)
            case _ => ()
        }
    }

    private func attr(attrs: Array<XmlAttribute>, local: String): ?String {
        for (attribute in attrs) {
            if (attribute.name.local == local) {
                return Some(attribute.value)
            }
        }
        None<String>
    }

    private func onStart(local: String, attrs: Array<XmlAttribute>): Unit {
        match (local) {
            case "dimension" => parsed.dimension = attr(attrs, "ref")
            case "row" => startRow(attrs)
            case "c" => startCell(attrs)
            case "v" => inValue = true
            case "f" =>
                inFormula = true
                formulaType = attr(attrs, "t")
            case "is" => inInline = true
            case "t" => if (inInline) {
                inInlineText = true
            }
            case "mergeCell" => match (attr(attrs, "ref")) {
                case Some(ref) => parsed.merges.add(ref)
                case None => ()
            }
            case _ => ()
        }
    }

    private func onEnd(local: String): Unit {
        match (local) {
            case "v" => inValue = false
            case "f" => inFormula = false
            case "t" => inInlineText = false
            case "is" => inInline = false
            case "c" => finishCell()
            case "row" => finishRow()
            case _ => ()
        }
    }

    private func onText(value: String): Unit {
        if (inValue) {
            valueText.append<String>(value)
        } else if (inInlineText) {
            inlineText.append<String>(value)
        } else if (inFormula) {
            formulaText.append<String>(value)
        }
    }

    private func startRow(attrs: Array<XmlAttribute>): Unit {
        rowActive = true
        cells = ArrayList<Cell>()
        lastCol = 0
        let index = match (attr(attrs, "r")) {
            case Some(text) => match (parseIntOrNone(text)) {
                case Some(v) => v
                case None =>
                    parsed.warnings.add(
                        ExcelWarning(ExcelWarningKind.MissingRowIndex, "行号非法：${text}", sheet: Some(sheetName))
                    )
                    lastRow + 1
            }
            case None =>
                parsed.warnings.add(
                    ExcelWarning(ExcelWarningKind.MissingRowIndex, "缺少行号，按上一行 +1 推断", sheet: Some(sheetName))
                )
                lastRow + 1
        }
        rowIndex = index
        rowHeight = match (attr(attrs, "ht")) {
            case Some(text) => parseFloatOrNone(text)
            case None => None<Float64>
        }
        skipRow = false
        if (options.maxRows > 0 && Int64(parsed.rows.size) >= options.maxRows) {
            skipRow = true
            if (!maxRowWarned) {
                maxRowWarned = true
                parsed.warnings.add(
                    ExcelWarning(
                        ExcelWarningKind.MaxRowsTruncated,
                        "超过 maxRows=${options.maxRows}，后续行被截断",
                        sheet: Some(sheetName)
                    )
                )
            }
        }
    }

    private func startCell(attrs: Array<XmlAttribute>): Unit {
        cellActive = true
        skipCell = false
        cellType = attr(attrs, "t")
        valueText = StringGenerator()
        inlineText = StringGenerator()
        formulaText = StringGenerator()
        formulaType = None
        inValue = false
        inInline = false
        inInlineText = false
        inFormula = false
        col = match (attr(attrs, "r")) {
            case Some(text) => match (CellRef.parse(text)) {
                case Some(ref) => ref.col
                case None =>
                    parsed.warnings.add(
                        ExcelWarning(
                            ExcelWarningKind.InvalidCellRef,
                            "单元格引用非法：${text}",
                            sheet: Some(sheetName)
                        )
                    )
                    lastCol + 1
            }
            case None =>
                parsed.warnings.add(
                    ExcelWarning(ExcelWarningKind.MissingCellRef, "缺少单元格引用，按前一列 +1 推断", sheet: Some(sheetName))
                )
                lastCol + 1
        }
        lastCol = col
        if (options.maxCols > 0 && col > options.maxCols) {
            skipCell = true
            if (!maxColWarned) {
                maxColWarned = true
                parsed.warnings.add(
                    ExcelWarning(
                        ExcelWarningKind.MaxColsTruncated,
                        "超过 maxCols=${options.maxCols}，后续列被截断",
                        sheet: Some(sheetName)
                    )
                )
            }
        }
    }

    private func finishCell(): Unit {
        if (!cellActive) {
            return
        }
        cellActive = false
        if (!rowActive || skipCell) {
            return
        }
        cells.add(Cell(col, valueOf()))
    }

    private func valueOf(): CellValue {
        let formula = formulaText.toString()
        if (!formula.isEmpty() || formulaType.isSome()) {
            if (formulaType == Some("shared") && formula.isEmpty()) {
                parsed.warnings.add(
                    ExcelWarning(
                        ExcelWarningKind.SharedFormulaUnsupported,
                        "共享公式只保留原文（本格没有原文）",
                        sheet: Some(sheetName)
                    )
                )
                return CellValue.Empty
            }
            let cached = if (valueText.size == 0) {
                None<CellValue>
            } else {
                Some(plainValue())
            }
            return CellValue.Formula(formula, cached)
        }
        plainValue()
    }

    private func plainValue(): CellValue {
        let text = valueText.toString()
        let cellKind = cellType
        match (cellKind) {
            case Some("s") =>
                let index = match (parseIntOrNone(text)) {
                    case Some(v) => v
                    case None => -1
                }
                match (sst.get(index)) {
                    case Some(value) => CellValue.Text(value)
                    case None =>
                        parsed.warnings.add(
                            ExcelWarning(
                                ExcelWarningKind.SharedStringIndexOutOfRange,
                                "sharedStrings 索引越界：${text}",
                                sheet: Some(sheetName)
                            )
                        )
                        CellValue.Empty
                }
            case Some("inlineStr") => CellValue.Text(inlineText.toString())
            case Some("str") => CellValue.Text(text)
            case Some("b") => CellValue.Boolean(text == "1" || text.toAsciiLower() == "true")
            case Some("e") => CellValue.Error(text)
            case Some("d") => match (parseDateOrNone(text)) {
                case Some(v) => CellValue.Date(v)
                case None =>
                    parsed.warnings.add(
                        ExcelWarning(
                            ExcelWarningKind.NumberParseFailed,
                            "日期解析失败：${text}",
                            sheet: Some(sheetName)
                        )
                    )
                    CellValue.Text(text)
            }
            case Some(other) =>
                parsed.warnings.add(
                    ExcelWarning(
                        ExcelWarningKind.UnknownCellType,
                        "未知单元格类型 t=${other}，按文本保留",
                        sheet: Some(sheetName)
                    )
                )
                CellValue.Text(text)
            case None => if (text.isEmpty()) {
                CellValue.Empty
            } else {
                match (parseFloatOrNone(text)) {
                    case Some(v) => CellValue.Number(v)
                    case None =>
                        parsed.warnings.add(
                            ExcelWarning(
                                ExcelWarningKind.NumberParseFailed,
                                "数字解析失败：${text}",
                                sheet: Some(sheetName)
                            )
                        )
                        CellValue.Text(text)
                }
            }
        }
    }

    private func finishRow(): Unit {
        if (!rowActive) {
            return
        }
        rowActive = false
        if (skipRow) {
            return
        }
        parsed.rows.add(RowData(rowIndex, cells.toArray(), height: rowHeight))
        lastRow = rowIndex
    }
}
