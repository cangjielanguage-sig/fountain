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
package fountain::f_chart.tui

import std.collection.ArrayList

/** TUI 单元格：符号 + 前景色；宽字符的后半格标记为 continuation。 */
internal class TuiCell {
    var symbol: String = " "
    var color: String = ""
    var continuation: Bool = false
}

/** 字符网格：TUI 图表的最小绘制单元。 */
internal class TuiCanvas {
    let width: Int64
    let height: Int64
    private let cells: Array<TuiCell>

    init(width: Int64, height: Int64) {
        this.width = width
        this.height = height
        let list = ArrayList<TuiCell>()
        var index = 0
        while (index < width * height) {
            list.add(TuiCell())
            index++
        }
        this.cells = list.toArray()
    }

    func set(x: Int64, y: Int64, symbol: String, color: String): Unit {
        if (x < 0 || x >= this.width || y < 0 || y >= this.height) {
            return
        }
        let cell = this.cells[y * this.width + x]
        cell.symbol = symbol
        cell.color = color
        cell.continuation = false
    }

    private func markContinuation(x: Int64, y: Int64, color: String): Unit {
        if (x < 0 || x >= this.width || y < 0 || y >= this.height) {
            return
        }
        let cell = this.cells[y * this.width + x]
        cell.symbol = ""
        cell.color = color
        cell.continuation = true
    }

    /** 写文本；按显示宽度排布，超出可用列数时截断并补省略号。 */
    func putText(
        x: Int64,
        y: Int64,
        text: String,
        color: String,
        align!: String = "start",
        maxWidth!: Int64 = 0
    ): Unit {
        if (y < 0 || y >= this.height || x >= this.width) {
            return
        }
        var available = this.width - x
        if (maxWidth > 0 && maxWidth < available) {
            available = maxWidth
        }
        if (available <= 0) {
            return
        }
        let clipped = tuiTruncate(text, available)
        let clippedWidth = tuiDisplayWidth(clipped)
        var startX = x
        if (align == "middle") {
            startX = x + (available - clippedWidth) / 2
        } else if (align == "end") {
            startX = x + available - clippedWidth
        }
        if (startX < 0) {
            startX = 0
        }
        var cursor = startX
        for (rune in clipped.runes()) {
            let runeWidth = tuiRuneWidth(rune)
            if (cursor + runeWidth > this.width) {
                break
            }
            this.set(cursor, y, rune.toString(), color)
            if (runeWidth == 2) {
                this.markContinuation(cursor + 1, y, color)
            }
            cursor += runeWidth
        }
    }

    /** 整数 Bresenham 线段。 */
    func drawLine(
        x0: Int64,
        y0: Int64,
        x1: Int64,
        y1: Int64,
        symbol: String,
        color: String
    ): Unit {
        var currentX = x0
        var currentY = y0
        let deltaX = if (x1 >= x0) { x1 - x0 } else { x0 - x1 }
        let stepX = if (x0 < x1) { 1 } else if (x0 > x1) { -1 } else { 0 }
        let deltaY = if (y1 >= y0) { y1 - y0 } else { y0 - y1 }
        let stepY = if (y0 < y1) { 1 } else if (y0 > y1) { -1 } else { 0 }
        var error = deltaX - deltaY
        let negativeY = -deltaY
        while (true) {
            this.set(currentX, currentY, symbol, color)
            if (currentX == x1 && currentY == y1) {
                break
            }
            let doubled = error * 2
            if (doubled >= negativeY) {
                error -= deltaY
                currentX += stepX
            }
            if (doubled <= deltaX) {
                error += deltaX
                currentY += stepY
            }
        }
    }

    /** 纯文本行，每行恰好 `width` 个显示列，不含换行符。 */
    func plainLines(): Array<String> {
        let lines = ArrayList<String>()
        for (row in 0..this.height) {
            let builder = StringBuilder()
            for (column in 0..this.width) {
                let cell = this.cells[row * this.width + column]
                if (!cell.continuation) {
                    builder.append(cell.symbol)
                }
            }
            lines.add(builder.toString())
        }
        lines.toArray()
    }

    /** ANSI 真彩色字符串，每行以复位和换行结束。 */
    func render(): String {
        let builder = StringBuilder()
        for (row in 0..this.height) {
            var activeColor = ""
            for (column in 0..this.width) {
                let cell = this.cells[row * this.width + column]
                if (cell.continuation) {
                    continue
                }
                if (cell.color != activeColor) {
                    if (cell.color.isEmpty()) {
                        builder.append(tuiAnsiReset())
                    } else {
                        builder.append(tuiAnsiForeground(cell.color))
                    }
                    activeColor = cell.color
                }
                builder.append(cell.symbol)
            }
            builder.append(tuiAnsiReset())
            builder.append("\n")
        }
        builder.toString()
    }
}
