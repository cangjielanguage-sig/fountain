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

/** Excel 的行列上限（[Worksheet] 与设计 §9.4 共用）。 */
public let EXCEL_MAX_ROW: Int64 = 1_048_576
public let EXCEL_MAX_COL: Int64 = 16_384

private func isAsciiLetter(b: UInt8): Bool {
    (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
}

private func isAsciiDigit(b: UInt8): Bool {
    b >= 48 && b <= 57
}

/** 列字母 → 列号（1 起，大小写不敏感）；非法或越界返回 `None`。 */
public func columnIndex(letters: String): ?Int64 {
    if (letters.isEmpty()) {
        return None<Int64>
    }
    var col: Int64 = 0
    for (b in letters.toArray()) {
        if (!isAsciiLetter(b)) {
            return None<Int64>
        }
        let digit = if (b >= 97) {
            Int64(b - 96)
        } else {
            Int64(b - 64)
        }
        col = col * 26 + digit
        if (col > EXCEL_MAX_COL) {
            return None<Int64>
        }
    }
    Some(col)
}

/** 列号 → 大写列字母；`col < 1` 或 `> 16384` 抛 `ExcelException`。 */
public func columnLetters(col: Int64): String {
    if (col < 1 || col > EXCEL_MAX_COL) {
        throw ExcelException("列号 ${col} 超出范围 1..${EXCEL_MAX_COL}")
    }
    let reversed = ArrayList<UInt8>()
    var n = col
    while (n > 0) {
        let rem = (n - 1) % 26
        reversed.add(UInt8(65 + rem))
        n = (n - 1) / 26
    }
    let bytes = Array<UInt8>(reversed.size, repeat: 0)
    for (i in 0..reversed.size) {
        bytes[reversed.size - 1 - i] = reversed[i]
    }
    String.fromUtf8(bytes)
}

/**
 * A1 引用（值类型）。
 *
 * 比较与相等只看 `row` / `col`（`$` 是显示属性，不参与身份）。
 */
public struct CellRef <: Comparable<CellRef> & Equatable<CellRef> & ToString {
    public let row: Int64
    public let col: Int64
    public let rowAbs: Bool
    public let colAbs: Bool

    public init(row: Int64, col: Int64, rowAbs!: Bool = false, colAbs!: Bool = false) {
        this.row = row
        this.col = col
        this.rowAbs = rowAbs
        this.colAbs = colAbs
    }

    /**
     * 严格解析：`$` 位置、前导零、越界、尾随垃圾全部按设计 §11.6 的表处理，
     * **不做"尽力返回"**。
     */
    public static func parse(s: String): ?CellRef {
        if (s.isEmpty()) {
            return None<CellRef>
        }
        let bytes = s.toArray()
        let n = bytes.size
        var i: Int64 = 0
        var colAbs = false
        if (i < n && bytes[i] == 36u8) {
            colAbs = true
            i++
        }
        let colStart = i
        while (i < n && isAsciiLetter(bytes[i])) {
            i++
        }
        if (i == colStart) {
            return None<CellRef>
        }
        let col = match (columnIndex(String.fromUtf8(bytes[colStart..i]))) {
            case Some(v) => v
            case None => return None<CellRef>
        }
        var rowAbs = false
        if (i < n && bytes[i] == 36u8) {
            rowAbs = true
            i++
        }
        let rowStart = i
        while (i < n && isAsciiDigit(bytes[i])) {
            i++
        }
        if (i == rowStart || i != n) {
            return None<CellRef>
        }
        let row = try {
            Int64.parse(String.fromUtf8(bytes[rowStart..i]))
        } catch (_: Exception) {
            return None<CellRef>
        }
        if (row < 1 || row > EXCEL_MAX_ROW) {
            return None<CellRef>
        }
        Some(CellRef(row, col, rowAbs: rowAbs, colAbs: colAbs))
    }

    /** 单 `:` 的区域；单格 `A1` 返回 `Some((A1, A1))`；倒置或多冒号返回 `None`。 */
    public static func parseRange(s: String): ?(CellRef, CellRef) {
        let bytes = s.toArray()
        var separator: Int64 = -1
        for (i in 0..bytes.size) {
            if (bytes[i] == 58u8) {
                if (separator >= 0) {
                    return None<(CellRef, CellRef)>
                }
                separator = i
            }
        }
        if (separator < 0) {
            let single = match (parse(s)) {
                case Some(v) => v
                case None => return None<(CellRef, CellRef)>
            }
            return Some((single, single))
        }
        let from = match (parse(String.fromUtf8(bytes[0..separator]))) {
            case Some(v) => v
            case None => return None<(CellRef, CellRef)>
        }
        let to = match (parse(String.fromUtf8(bytes[separator + 1..bytes.size]))) {
            case Some(v) => v
            case None => return None<(CellRef, CellRef)>
        }
        if (from.row > to.row || from.col > to.col) {
            return None<(CellRef, CellRef)>
        }
        Some((from, to))
    }

    public func toString(): String {
        "${columnLetters(this.col)}${this.row}"
    }

    public func toA1(): String {
        let colMark = if (this.colAbs) { "$" } else { "" }
        let rowMark = if (this.rowAbs) { "$" } else { "" }
        "${colMark}${columnLetters(this.col)}${rowMark}${this.row}"
    }

    /** 先行后列。 */
    public func compare(that: CellRef): Ordering {
        if (this.row < that.row) {
            return LT
        }
        if (this.row > that.row) {
            return GT
        }
        if (this.col < that.col) {
            return LT
        }
        if (this.col > that.col) {
            return GT
        }
        EQ
    }

    public operator func ==(that: CellRef): Bool {
        this.row == that.row && this.col == that.col
    }

    public operator func !=(that: CellRef): Bool {
        !(this == that)
    }
}
