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

import std.collection.{ArrayList, HashMap}
import std.fs.Path

/**
 * 一张工作表（整文档模型）。
 *
 * 单元格稀疏存储：只保存实际出现过的格子；`Some(CellValue.Empty)` 表示"文件里有这个
 * `<c>` 但值为空"，与"没有这个格子（`None`）"不同——这个区分是设计 2.4 的硬要求。
 */
public class Worksheet {
    private let sheetName: String
    private let cells = HashMap<Int64, CellValue>()
    private let merges = ArrayList<String>()
    private let images = ArrayList<SheetImage>()
    private let stylesMap = HashMap<Int64, CellStyle>()
    private let richTexts = HashMap<Int64, RichText>()
    private let conditionalFormatsList = ArrayList<ConditionalFormat>()
    private var loader: ?() -> Unit = None
    private var dimensionRef: ?String = None
    private var maxRowSeen: Int64 = 0
    private var maxColSeen: Int64 = 0

    internal init(name: String) {
        this.sheetName = name
    }

    public prop name: String {
        get() {
            sheetName
        }
    }

    /** 懒加载：`eager=false` 时由文档注入；首次访问触发一次解析。 */
    internal func setLoader(load: () -> Unit): Unit {
        this.loader = Some(load)
    }

    private func ensureLoaded(): Unit {
        match (this.loader) {
            case Some(load) =>
                this.loader = None
                load()
            case None => ()
        }
    }

    public func rowCount(): Int64 {
        this.ensureLoaded()
        maxRowSeen
    }

    public func colCount(): Int64 {
        this.ensureLoaded()
        maxColSeen
    }

    public func dimension(): ?String {
        this.ensureLoaded()
        dimensionRef
    }

    internal func setDimension(value: ?String): Unit {
        dimensionRef = value
    }

    private static func key(row: Int64, col: Int64): Int64 {
        row * (EXCEL_MAX_COL + 1) + col
    }

    private static func valid(row: Int64, col: Int64): Bool {
        row >= 1 && row <= EXCEL_MAX_ROW && col >= 1 && col <= EXCEL_MAX_COL
    }

    public func cell(row: Int64, col: Int64): ?CellValue {
        this.ensureLoaded()
        if (!valid(row, col)) {
            return None<CellValue>
        }
        cells.get(key(row, col))
    }

    public func cell(ref: String): ?CellValue {
        this.ensureLoaded()
        match (CellRef.parse(ref)) {
            case Some(r) => cell(r.row, r.col)
            case None => None<CellValue>
        }
    }

    public func cell(ref: CellRef): ?CellValue {
        this.ensureLoaded()
        cell(ref.row, ref.col)
    }

    public func setCell(row: Int64, col: Int64, value: CellValue): Unit {
        this.ensureLoaded()
        if (!valid(row, col)) {
            throw ExcelException("单元格 (${row}, ${col}) 超出 Excel 上限")
        }
        cells.add(key(row, col), value)
        if (row > maxRowSeen) {
            maxRowSeen = row
        }
        if (col > maxColSeen) {
            maxColSeen = col
        }
    }

    public func setCell(ref: String, value: CellValue): Unit {
        this.ensureLoaded()
        let r = match (CellRef.parse(ref)) {
            case Some(v) => v
            case None => throw ExcelException("非法的单元格引用：${ref}")
        }
        setCell(r.row, r.col, value)
    }

    public func setCell(ref: CellRef, value: CellValue): Unit {
        this.ensureLoaded()
        setCell(ref.row, ref.col, value)
    }

    /** 条件格式（按解析/添加顺序）。 */
    public func conditionalFormats(): ArrayList<ConditionalFormat> {
        this.ensureLoaded()
        this.conditionalFormatsList
    }

    /** 追加一组条件格式；同 `range` 的规则合并到同一组。 */
    public func addConditionalFormat(range: String, rule: CfRule): Unit {
        this.ensureLoaded()
        match (CellRef.parseRange(range)) {
            case Some(_) => ()
            case None => throw ExcelException("非法的条件格式区域：${range}")
        }
        for (item in this.conditionalFormatsList) {
            if (item.range == range) {
                item.rules.add(rule)
                return
            }
        }
        let rules = ArrayList<CfRule>()
        rules.add(rule)
        this.conditionalFormatsList.add(ConditionalFormat(range, rules))
    }

    /** 值规则命中（不含 `expression`，它需要公式引擎）。 */
    public func matchedRules(row: Int64, col: Int64): ArrayList<CfMatch> {
        this.ensureLoaded()
        this.matchedRulesWith(row, col, None)
    }

    internal func matchedRulesWith(
        row: Int64,
        col: Int64,
        expression: ?(String) -> CalcValue
    ): ArrayList<CfMatch> {
        let result = ArrayList<CfMatch>()
        if (!valid(row, col)) {
            return result
        }
        let value = match (this.cell(row, col)) {
            case Some(v) => cellValueToCalc(v, false)
            case None => CalcValue.Empty
        }
        for (format in this.conditionalFormatsList) {
            if (!sqrefContains(format.range, row, col)) {
                continue
            }
            let rangeValues = this.valuesOfRange(format.range)
            let sorted = ArrayList<CfRule>()
            for (rule in format.rules) {
                sorted.add(rule)
            }
            for (i in 1..sorted.size) {
                let key = sorted[i]
                var j = i - 1
                while (j >= 0 && sorted[j].priority > key.priority) {
                    sorted[j + 1] = sorted[j]
                    j--
                }
                sorted[j + 1] = key
            }
            let shiftedEval = match (expression) {
                case Some(eval) =>
                    let deltaRow = match (CellRef.parseRange(format.range)) {
                        case Some(bounds) => row - bounds[0].row
                        case None => 0
                    }
                    let deltaCol = match (CellRef.parseRange(format.range)) {
                        case Some(bounds) => col - bounds[0].col
                        case None => 0
                    }
                    Some({ formula: String => eval(shiftFormula(formula, deltaRow, deltaCol)) })
                case None => None<(String) -> CalcValue>
            }
            for (rule in sorted) {
                match (cfRuleHit(rule, value, rangeValues, this.name, CellRef(row, col), shiftedEval)) {
                    case Some(hit) =>
                        result.add(CfMatch(rule, hit))
                        if (rule.stopIfTrue) {
                            break
                        }
                    case None => ()
                }
            }
        }
        result
    }

    private func valuesOfRange(range: String): ArrayList<CalcValue> {
        let values = ArrayList<CalcValue>()
        for (part in range.split(" ")) {
            if (part.isEmpty()) {
                continue
            }
            match (CellRef.parseRange(part)) {
                case Some(bounds) =>
                    let (from, to) = bounds
                    var row = from.row
                    while (row <= to.row) {
                        var col = from.col
                        while (col <= to.col) {
                            match (this.cell(row, col)) {
                                case Some(v) => values.add(cellValueToCalc(v, false))
                                case None => values.add(CalcValue.Empty)
                            }
                            col++
                        }
                        row++
                    }
                case None => ()
            }
        }
        values
    }

    /** 富文本（`sharedStrings` 的分段样式）；不是富文本返回 `None`。 */
    public func richText(row: Int64, col: Int64): ?RichText {
        this.ensureLoaded()
        if (!valid(row, col)) {
            return None<RichText>
        }
        richTexts.get(key(row, col))
    }

    public func setRichText(row: Int64, col: Int64, value: RichText): Unit {
        this.ensureLoaded()
        if (!valid(row, col)) {
            throw ExcelException("单元格 (${row}, ${col}) 超出 Excel 上限")
        }
        richTexts.add(key(row, col), value)
    }

    /** 读取某格的完整样式；没有显式样式返回 `None`。 */
    public func styleOf(row: Int64, col: Int64): ?CellStyle {
        this.ensureLoaded()
        if (!valid(row, col)) {
            return None<CellStyle>
        }
        stylesMap.get(key(row, col))
    }

    public func setStyle(row: Int64, col: Int64, style: CellStyle): Unit {
        this.ensureLoaded()
        if (!valid(row, col)) {
            throw ExcelException("单元格 (${row}, ${col}) 超出 Excel 上限")
        }
        stylesMap.add(key(row, col), style)
        if (row > maxRowSeen) {
            maxRowSeen = row
        }
        if (col > maxColSeen) {
            maxColSeen = col
        }
    }

    public func clearCell(row: Int64, col: Int64): Unit {
        this.ensureLoaded()
        if (!valid(row, col)) {
            return
        }
        cells.remove(key(row, col))
    }

    public func clearCell(ref: String): Unit {
        this.ensureLoaded()
        match (CellRef.parse(ref)) {
            case Some(r) => clearCell(r.row, r.col)
            case None => ()
        }
    }

    /** 左上 → 右下；缺失的格子给 `Empty`。 */
    public func range(from: String, to: String): Array<Array<CellValue>> {
        this.ensureLoaded()
        let parsed = match (CellRef.parseRange("${from}:${to}")) {
            case Some(v) => v
            case None => throw ExcelException("非法的区域：${from}:${to}")
        }
        let (start, end) = parsed
        let rows = end.row - start.row + 1
        let cols = end.col - start.col + 1
        let block = Array<Array<CellValue>>(rows, repeat: Array<CellValue>(0, repeat: CellValue.Empty))
        for (i in 0..rows) {
            let line = Array<CellValue>(cols, repeat: CellValue.Empty)
            for (j in 0..cols) {
                match (cell(start.row + i, start.col + j)) {
                    case Some(v) => line[j] = v
                    case None => ()
                }
            }
            block[i] = line
        }
        block
    }

    /** 一行里实际出现的格子，按列升序。 */
    public func rowValues(row: Int64): Array<(Int64, CellValue)> {
        this.ensureLoaded()
        let out = ArrayList<(Int64, CellValue)>()
        if (row < 1 || row > EXCEL_MAX_ROW) {
            return out.toArray()
        }
        for (col in 1..=maxColSeen) {
            match (cells.get(key(row, col))) {
                case Some(v) => out.add((col, v))
                case None => ()
            }
        }
        out.toArray()
    }

    /** 把图片锚定到 `[from, to]` 单元格区域（写侧；读侧 M1.5 不解析图片）。 */
    public func addImage(path: Path, from: String, to: String): Unit {
        this.ensureLoaded()
        let (data, format) = readImage(path)
        addImage(data, format, from, to)
    }

    public func addImage(data: Array<Byte>, format: ImageFormat, from: String, to: String): Unit {
        this.ensureLoaded()
        let start = match (CellRef.parse(from)) {
            case Some(v) => v
            case None => throw ExcelException("非法的图片起始单元格：${from}")
        }
        let end = match (CellRef.parse(to)) {
            case Some(v) => v
            case None => throw ExcelException("非法的图片结束单元格：${to}")
        }
        if (start.row > end.row || start.col > end.col) {
            throw ExcelException("图片区域倒置：${from}:${to}")
        }
        if (data.size == 0) {
            throw ExcelException("图片数据为空")
        }
        images.add(SheetImage(data, format, start, end))
    }

    public func imageCount(): Int64 {
        this.ensureLoaded()
        Int64(images.size)
    }

    internal func sheetImages(): ArrayList<SheetImage> {
        this.ensureLoaded()
        images
    }

    public func mergedRanges(): ArrayList<String> {
        this.ensureLoaded()
        merges
    }

    public func mergedRangeAt(row: Int64, col: Int64): ?String {
        this.ensureLoaded()
        for (range in merges) {
            let parsed = CellRef.parseRange(range)
            match (parsed) {
                case Some(bounds) =>
                    let (start, end) = bounds
                    if (row >= start.row && row <= end.row && col >= start.col && col <= end.col) {
                        return Some(range)
                    }
                case None => ()
            }
        }
        None<String>
    }

    public func mergedValue(row: Int64, col: Int64): ?CellValue {
        this.ensureLoaded()
        match (mergedRangeAt(row, col)) {
            case Some(range) =>
                match (CellRef.parseRange(range)) {
                    case Some(bounds) => cell(bounds[0].row, bounds[0].col)
                    case None => None<CellValue>
                }
            case None => None<CellValue>
        }
    }

    public func merge(range: String): Unit {
        this.ensureLoaded()
        let parsed = match (CellRef.parseRange(range)) {
            case Some(v) => v
            case None => throw ExcelException("非法的合并区域：${range}")
        }
        let canonical = "${parsed[0].toString()}:${parsed[1].toString()}"
        for (existing in merges) {
            match (CellRef.parseRange(existing)) {
                case Some(bounds) =>
                    let (aStart, aEnd) = bounds
                    let (bStart, bEnd) = parsed
                    let disjoint = aEnd.row < bStart.row || bEnd.row < aStart.row ||
                        aEnd.col < bStart.col || bEnd.col < aStart.col
                    if (!disjoint) {
                        throw ExcelException("合并区域 ${canonical} 与 ${existing} 重叠")
                    }
                case None => ()
            }
        }
        merges.add(canonical)
    }

    public func merge(from: String, to: String): Unit {
        this.ensureLoaded()
        merge("${from}:${to}")
    }

    public func unmerge(range: String): Bool {
        this.ensureLoaded()
        let parsed = match (CellRef.parseRange(range)) {
            case Some(v) => v
            case None => return false
        }
        let canonical = "${parsed[0].toString()}:${parsed[1].toString()}"
        for (i in 0..merges.size) {
            if (merges[i] == canonical) {
                merges.remove(at: i)
                return true
            }
        }
        false
    }
}
