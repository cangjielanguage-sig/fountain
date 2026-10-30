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

/** 一次重算的结果摘要。 */
public struct CalcReport <: ToString {
    /** 重算过的公式单元格数。 */
    public let recalculated: Int64
    /** 结果是错误值的单元格数。 */
    public let errors: Int64
    /** 环上的单元格键（`Sheet1!A1`）。 */
    public let cycles: ArrayList<String>
    /** 解析失败 / 未知函数等问题。 */
    public let issues: ArrayList<String>

    public init(
        recalculated: Int64,
        errors: Int64,
        cycles!: ArrayList<String> = ArrayList<String>(),
        issues!: ArrayList<String> = ArrayList<String>()
    ) {
        this.recalculated = recalculated
        this.errors = errors
        this.cycles = cycles
        this.issues = issues
    }

    public func toString(): String {
        "CalcReport(recalculated=${this.recalculated}, errors=${this.errors}, cycles=${this.cycles.size})"
    }
}

/** 解析器实现：把文档 + 当前工作表上下文暴露给 [Evaluator]。 */
internal class DocumentResolver <: CalcResolver {
    public var engine: ?CalcEngine = None
    public var currentSheet: String = ""

    public init() {}

    public func valueAt(sheet: String, row: Int64, col: Int64): CalcValue {
        this.engine.getOrThrow().lookup(sheet, row, col)
    }

    public func sheetExists(name: String): Bool {
        if (name.isEmpty()) {
            return true
        }
        this.engine.getOrThrow().document().sheet(name).isSome()
    }

    public func usedBounds(sheet: String): (Int64, Int64) {
        this.engine.getOrThrow().boundsOf(sheet)
    }

    public func date1904(): Bool {
        this.engine.getOrThrow().document().date1904
    }
}

/**
 * 公式计算引擎（设计 7.6）。
 *
 * **默认不自动重算**：读文件拿缓存值；`evaluate` 是显式查询，`recalculate` 是显式重算。
 * 求值不修改文档，除非 `recalculate(writeBack: true)`。
 */
public class CalcEngine {
    private let doc: ExcelDocument
    private let resolver: DocumentResolver
    private var memo = HashMap<String, CalcValue>()
    private var inProgress = ArrayList<String>()
    private var cycleCells = ArrayList<String>()
    private var issues = ArrayList<String>()

    public init(doc: ExcelDocument) {
        this.doc = doc
        this.resolver = DocumentResolver()
        this.resolver.engine = this
    }

    public func document(): ExcelDocument {
        this.doc
    }

    /** 单格求值；公式会现场求值（不读缓存），常量直接返回。 */
    public func evaluate(sheet: String, ref: String): CalcValue {
        let cellRef = match (CellRef.parse(ref)) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Ref)
        }
        this.memo = HashMap<String, CalcValue>()
        this.inProgress = ArrayList<String>()
        this.cycleCells = ArrayList<String>()
        this.issues = ArrayList<String>()
        this.resolver.currentSheet = sheet
        this.lookup(sheet, cellRef.row, cellRef.col)
    }

    public func evaluate(sheet: String, ref: CellRef): CalcValue {
        this.evaluate(sheet, ref.toA1())
    }

    /** 单格求值并转成 `CellValue`。 */
    public func evaluateCell(sheet: String, ref: String): CellValue {
        calcToCellValue(this.evaluate(sheet, ref))
    }

    /**
     * 重算（默认全表）。
     *
     * - `sheet` 指定时只算该表；
     * - `writeBack = true` 把结果写回公式的缓存值（公式原文保留）。
     */
    public func recalculate(sheet!: ?String = None, writeBack!: Bool = false): CalcReport {
        this.memo = HashMap<String, CalcValue>()
        this.inProgress = ArrayList<String>()
        this.cycleCells = ArrayList<String>()
        this.issues = ArrayList<String>()
        var recalculated: Int64 = 0
        var errors: Int64 = 0
        let targets = ArrayList<String>()
        match (sheet) {
            case Some(name) => targets.add(name)
            case None =>
                for (item in this.doc.sheets()) {
                    targets.add(item.name)
                }
        }
        for (name in targets) {
            let worksheet = match (this.doc.sheet(name)) {
                case Some(v) => v
                case None => continue
            }
            this.resolver.currentSheet = name
            let rowCount = worksheet.rowCount()
            var row: Int64 = 1
            while (row <= rowCount) {
                for (pair in worksheet.rowValues(row)) {
                    let value = pair[1]
                    match (value) {
                        case Formula(source, _) =>
                            recalculated++
                            let result = this.lookup(name, row, pair[0])
                            if (result.isError()) {
                                errors++
                            }
                            if (writeBack) {
                                worksheet.setCell(
                                    row,
                                    pair[0],
                                    CellValue.Formula(source, Some(calcToCellValue(result)))
                                )
                            }
                        case _ => ()
                    }
                }
                row++
            }
        }
        CalcReport(recalculated, errors, cycles: this.cycleCells, issues: this.issues)
    }

    /** 依赖图：把当前所有公式单元格登记进去（`recalculate` 前可用）。 */
    public func buildGraph(): DependencyGraph {
        let graph = DependencyGraph()
        for (worksheet in this.doc.sheets()) {
            let rowCount = worksheet.rowCount()
            var row: Int64 = 1
            while (row <= rowCount) {
                for (pair in worksheet.rowValues(row)) {
                    match (pair[1]) {
                        case Formula(source, _) => graph.add(worksheet.name, row, pair[0], source)
                        case _ => ()
                    }
                }
                row++
            }
        }
        graph
    }

    // ---------------------------------------------------------------- 内部

    /** 按表名 + 坐标取值；`sheet` 为空表示当前上下文工作表。 */
    internal func lookup(sheet: String, row: Int64, col: Int64): CalcValue {
        let name = if (sheet.isEmpty()) { this.resolver.currentSheet } else { sheet }
        if (name.isEmpty()) {
            return CalcValue.Error(CalcError.Ref)
        }
        let worksheet = match (this.doc.sheet(name)) {
            case Some(v) => v
            case None => return CalcValue.Error(CalcError.Ref)
        }
        let key = cellKey(name, row, col)
        match (this.memo.get(key)) {
            case Some(value) => return value
            case None => ()
        }
        let raw = match (worksheet.cell(row, col)) {
            case Some(v) => v
            case None =>
                this.memo.add(key, CalcValue.Empty)
                return CalcValue.Empty
        }
        let result = match (raw) {
            case Formula(source, _) =>
                if (this.inProgress.contains(key)) {
                    if (!this.cycleCells.contains(key)) {
                        this.cycleCells.add(key)
                    }
                    CalcValue.Error(CalcError.Circular)
                } else {
                    let expr = match (FormulaParser.parse(source)) {
                        case Some(v) => v
                        case None =>
                            this.issues.add("${key} 公式无法解析：=${source}")
                            this.memo.add(key, CalcValue.Error(CalcError.Name))
                            return CalcValue.Error(CalcError.Name)
                    }
                    this.inProgress.add(key)
                    let previous = this.resolver.currentSheet
                    this.resolver.currentSheet = name
                    let value = Evaluator(this.resolver).eval(expr)
                    this.resolver.currentSheet = previous
                    this.inProgress.remove(at: this.inProgress.size - 1)
                    if (value.isError()) {
                        match (value.asError()) {
                            case Some(e) => if (e == CalcError.Name) {
                                this.issues.add("${key} 求值失败：${e}")
                            }
                            case None => ()
                        }
                    }
                    value
                }
            case other => cellValueToCalc(other, this.doc.date1904)
        }
        this.memo.add(key, result)
        result
    }

    internal func boundsOf(sheet: String): (Int64, Int64) {
        let name = if (sheet.isEmpty()) { this.resolver.currentSheet } else { sheet }
        match (this.doc.sheet(name)) {
            case Some(worksheet) =>
                let rows = if (worksheet.rowCount() == 0) { 1 } else { worksheet.rowCount() }
                let cols = if (worksheet.colCount() == 0) { 1 } else { worksheet.colCount() }
                (rows, cols)
            case None => (1, 1)
        }
    }
}
