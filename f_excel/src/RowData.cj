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

/**
 * 行里的一个单元格（读写共用）。
 *
 * `col` 1 起；`cells` 在 [RowData] 里必须按 `col` 严格升序，且只含实际出现的单元格。
 * `numberFormat = None` 表示"按值类型自动决定"（写侧）。
 */
public struct Cell {
    public let col: Int64
    public let value: CellValue
    public let numberFormat: ?NumberFormat

    public init(col: Int64, value: CellValue, numberFormat!: ?NumberFormat = None) {
        this.col = col
        this.value = value
        this.numberFormat = numberFormat
    }

    public func toString(): String {
        "${columnLetters(this.col)}=${this.value}"
    }
}

/**
 * 读写共用的行模型。
 *
 * 读侧产出与写侧消费是同一组类型，`RowReader` 可直接作为 `Iterator<RowData>`
 * 喂给 `ExcelWriter.writeSheet`——不需要中间转换。
 */
public struct RowData {
    public let index: Int64
    public let cells: Array<Cell>
    public let height: ?Float64

    public init(index: Int64, cells: Array<Cell>, height!: ?Float64 = None) {
        this.index = index
        this.cells = cells
        this.height = height
    }

    public func toString(): String {
        "RowData(${this.index}, ${this.cells.size} cells)"
    }
}
