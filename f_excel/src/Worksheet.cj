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

    public func rowCount(): Int64 {
        maxRowSeen
    }

    public func colCount(): Int64 {
        maxColSeen
    }

    public func dimension(): ?String {
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
        if (!valid(row, col)) {
            return None<CellValue>
        }
        cells.get(key(row, col))
    }

    public func cell(ref: String): ?CellValue {
        match (CellRef.parse(ref)) {
            case Some(r) => cell(r.row, r.col)
            case None => None<CellValue>
        }
    }

    public func cell(ref: CellRef): ?CellValue {
        cell(ref.row, ref.col)
    }

    public func setCell(row: Int64, col: Int64, value: CellValue): Unit {
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
        let r = match (CellRef.parse(ref)) {
            case Some(v) => v
            case None => throw ExcelException("非法的单元格引用：${ref}")
        }
        setCell(r.row, r.col, value)
    }

    public func setCell(ref: CellRef, value: CellValue): Unit {
        setCell(ref.row, ref.col, value)
    }

    public func clearCell(row: Int64, col: Int64): Unit {
        if (!valid(row, col)) {
            return
        }
        cells.remove(key(row, col))
    }

    public func clearCell(ref: String): Unit {
        match (CellRef.parse(ref)) {
            case Some(r) => clearCell(r.row, r.col)
            case None => ()
        }
    }

    /** 左上 → 右下；缺失的格子给 `Empty`。 */
    public func range(from: String, to: String): Array<Array<CellValue>> {
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
        let (data, format) = readImage(path)
        addImage(data, format, from, to)
    }

    public func addImage(data: Array<Byte>, format: ImageFormat, from: String, to: String): Unit {
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
        Int64(images.size)
    }

    internal func sheetImages(): ArrayList<SheetImage> {
        images
    }

    public func mergedRanges(): ArrayList<String> {
        merges
    }

    public func mergedRangeAt(row: Int64, col: Int64): ?String {
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
        merge("${from}:${to}")
    }

    public func unmerge(range: String): Bool {
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
