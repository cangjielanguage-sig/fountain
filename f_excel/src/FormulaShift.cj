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
import fountain::f_base.StringGenerator

private func shiftIsLetter(r: Rune): Bool {
    (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z')
}

private func shiftIsDigit(r: Rune): Bool {
    r >= r'0' && r <= r'9'
}

/**
 * 共享公式平移：把主公式里的相对引用按 `(dRow, dCol)` 移动，`$` 修饰的坐标不动。
 *
 * 字符串字面量与带引号的工作表名原样复制，避免误伤 `"A1"` 这样的文本。
 * 平移越界写成 `#REF!`——与 Excel 一致。
 */
internal func shiftFormula(source: String, dRow: Int64, dCol: Int64): String {
    if (dRow == 0 && dCol == 0) {
        return source
    }
    let runes = ArrayList<Rune>()
    for (r in source.runes()) {
        runes.add(r)
    }
    let out = StringGenerator()
    var i: Int64 = 0
    let n = runes.size
    while (i < n) {
        let r = runes[i]
        if (r == r'"') {
            out.append(r)
            i++
            while (i < n) {
                out.append(runes[i])
                if (runes[i] == r'"') {
                    if (i + 1 < n && runes[i + 1] == r'"') {
                        out.append(runes[i + 1])
                        i += 2
                        continue
                    }
                    i++
                    break
                }
                i++
            }
            continue
        }
        if (r == r'\'') {
            out.append(r)
            i++
            while (i < n) {
                out.append(runes[i])
                if (runes[i] == r'\'') {
                    if (i + 1 < n && runes[i + 1] == r'\'') {
                        out.append(runes[i + 1])
                        i += 2
                        continue
                    }
                    i++
                    break
                }
                i++
            }
            continue
        }
        if (shiftIsLetter(r) || r == r'$') {
            let start = i
            var colAbs = false
            if (runes[i] == r'$') {
                colAbs = true
                i++
            }
            let lettersStart = i
            while (i < n && shiftIsLetter(runes[i])) {
                i++
            }
            let lettersEnd = i
            var rowAbs = false
            if (i < n && runes[i] == r'$') {
                rowAbs = true
                i++
            }
            let digitsStart = i
            while (i < n && shiftIsDigit(runes[i])) {
                i++
            }
            let digitsEnd = i
            let hasLetters = lettersEnd > lettersStart
            let hasDigits = digitsEnd > digitsStart
            let nextIsIdent = i < n && (shiftIsLetter(runes[i]) || shiftIsDigit(runes[i]) ||
                runes[i] == r'_' || runes[i] == r'.' || runes[i] == r'$')
            let isCall = i < n && runes[i] == r'('
            if (!hasLetters || !hasDigits || nextIsIdent || isCall) {
                // 不是引用：原样吐出这一段
                var j = start
                while (j < i) {
                    out.append(runes[j])
                    j++
                }
                continue
            }
            let letters = runesText(runes, lettersStart, lettersEnd)
            let digits = runesText(runes, digitsStart, digitsEnd)
            let colOption = columnIndex(letters)
            if (colOption.isNone()) {
                var j = start
                while (j < i) {
                    out.append(runes[j])
                    j++
                }
                continue
            }
            let col = colOption.getOrThrow()
            let row = try {
                Int64.parse(digits)
            } catch (_: Exception) {
                -1
            }
            if (row < 1) {
                var j = start
                while (j < i) {
                    out.append(runes[j])
                    j++
                }
                continue
            }
            let newCol = if (colAbs) { col } else { col + dCol }
            let newRow = if (rowAbs) { row } else { row + dRow }
            if (newCol < 1 || newCol > EXCEL_MAX_COL || newRow < 1 || newRow > EXCEL_MAX_ROW) {
                out.append<String>("#REF!")
                continue
            }
            if (colAbs) {
                out.append<String>("$")
            }
            out.append<String>(columnLetters(newCol))
            if (rowAbs) {
                out.append<String>("$")
            }
            out.append<String>(newRow.toString())
            continue
        }
        out.append(r)
        i++
    }
    out.toString()
}

private func runesText(runes: ArrayList<Rune>, start: Int64, end: Int64): String {
    let out = StringGenerator()
    var i = start
    while (i < end) {
        out.append(runes[i])
        i++
    }
    out.toString()
}
