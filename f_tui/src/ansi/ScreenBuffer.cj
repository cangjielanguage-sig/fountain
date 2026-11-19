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
package fountain::f_tui.ansi

/// 一个终端单元格。
public struct ScreenCell {
    /// 显示内容（已剔除控制字符）。
    public var symbol: String
    /// 前景色。
    public var fg: AnsiColor
    /// 背景色。
    public var bg: AnsiColor
    /// 修饰符位集合，取值见 `MODIFIER_*`。
    public var modifier: Int64
    /// 宽字符的第二列占位，渲染时跳过。
    public var skip: Bool

    public init(symbol: String, fg!: AnsiColor = AnsiColor.Default,
        bg!: AnsiColor = AnsiColor.Default, modifier!: Int64 = 0, skip!: Bool = false) {
        this.symbol = symbol
        this.fg = fg
        this.bg = bg
        this.modifier = modifier
        this.skip = skip
    }

    /// 是否使用默认样式。
    public func isPlain(): Bool {
        fg.isDefault() && bg.isDefault() && modifier == 0
    }

    public func equals(other: ScreenCell): Bool {
        symbol == other.symbol && skip == other.skip && modifier == other.modifier &&
            fg.equals(other.fg) && bg.equals(other.bg)
    }
}

/// 符号的显示宽度（控制字符已在清洗阶段替换）。
public func displayWidth(symbol: String): Int64 {
    var width: Int64 = 0
    for (rune in symbol.runes()) {
        width += runeWidth(rune)
    }
    width
}

func runeWidth(rune: Rune): Int64 {
    let code = Int64(UInt32(rune))
    if (code == 0) {
        return 0
    }
    if (code < 32 || (code >= 0x7F && code < 0xA0)) {
        return 0
    }
    // 组合字符不额外占列。
    if ((code >= 0x0300 && code <= 0x036F) || (code >= 0x1AB0 && code <= 0x1AFF) ||
        (code >= 0x1DC0 && code <= 0x1DFF) || (code >= 0x20D0 && code <= 0x20FF) ||
        (code >= 0xFE20 && code <= 0xFE2F)) {
        return 0
    }
    if (isWide(code)) {
        2
    } else {
        1
    }
}

func isWide(code: Int64): Bool {
    (code >= 0x1100 && code <= 0x115F) ||
    (code >= 0x2E80 && code <= 0x303E) ||
    (code >= 0x3041 && code <= 0x33FF) ||
    (code >= 0x3400 && code <= 0x4DBF) ||
    (code >= 0x4E00 && code <= 0x9FFF) ||
    (code >= 0xA000 && code <= 0xA4CF) ||
    (code >= 0xAC00 && code <= 0xD7A3) ||
    (code >= 0xF900 && code <= 0xFAFF) ||
    (code >= 0xFE10 && code <= 0xFE19) ||
    (code >= 0xFE30 && code <= 0xFE6F) ||
    (code >= 0xFF00 && code <= 0xFF60) ||
    (code >= 0xFFE0 && code <= 0xFFE6) ||
    (code >= 0x1F300 && code <= 0x1F64F) ||
    (code >= 0x1F900 && code <= 0x1F9FF) ||
    (code >= 0x20000 && code <= 0x3FFFD)
}

/// 把控制字符替换为 `?`，并保证空符号至少占一个空格。
public func sanitizeSymbol(symbol: String): String {
    let builder = StringBuilder()
    for (rune in symbol.runes()) {
        let code = Int64(UInt32(rune))
        if (code < 32 || (code >= 0x7F && code < 0xA0)) {
            builder.append("?")
        } else {
            builder.append(String([rune]))
        }
    }
    let value = builder.toString()
    if (value.isEmpty()) {
        " "
    } else {
        value
    }
}

/// 二维帧缓冲：保存每一列的可见字符与样式，作为差分渲染的基础。
public class ScreenBuffer {
    private let columns: UInt16
    private let rows: UInt16
    private var cells: Array<ScreenCell>

    public init(width: UInt16, height: UInt16) {
        this.columns = width
        this.rows = height
        this.cells = Array<ScreenCell>(Int64(width) * Int64(height),
            repeat: ScreenCell(" "))
    }

    /// 列数。
    public func width(): UInt16 {
        columns
    }

    /// 行数。
    public func height(): UInt16 {
        rows
    }

    /// 读取单元格；越界返回默认空格。
    public func get(x: UInt16, y: UInt16): ScreenCell {
        if (x >= columns || y >= rows) {
            ScreenCell(" ")
        } else {
            cells[indexOf(x, y)]
        }
    }

    /// 写入单元格，自动清洗控制字符并为宽字符标记第二列占位。
    public func set(x: UInt16, y: UInt16, value: ScreenCell): Unit {
        if (x >= columns || y >= rows) {
            return
        }
        let symbol = if (value.skip) {
            ""
        } else {
            sanitizeSymbol(value.symbol)
        }
        let normalized = ScreenCell(symbol, fg: value.fg, bg: value.bg, modifier: value.modifier,
            skip: value.skip)
        cells[indexOf(x, y)] = normalized
        if (!value.skip && displayWidth(symbol) >= 2 && x + 1 < columns) {
            cells[indexOf(x + 1, y)] = ScreenCell("", fg: value.fg, bg: value.bg,
                modifier: value.modifier, skip: true)
        } else if (!value.skip && x + 1 < columns && cells[indexOf(x + 1, y)].skip) {
            // 宽字符被窄字符覆盖时，清除遗留的占位列。
            cells[indexOf(x + 1, y)] = ScreenCell(" ")
        }
    }

    /// 复制当前帧。
    public func clone(): ScreenBuffer {
        let copy = ScreenBuffer(columns, rows)
        var y: UInt16 = 0
        while (y < rows) {
            var x: UInt16 = 0
            while (x < columns) {
                copy.cells[copy.indexOf(x, y)] = cells[indexOf(x, y)]
                x += 1
            }
            y += 1
        }
        copy
    }

    /// 两帧同位置单元格是否一致。
    public func sameCell(x: UInt16, y: UInt16, other: ScreenBuffer): Bool {
        get(x, y).equals(other.get(x, y))
    }

    private func indexOf(x: UInt16, y: UInt16): Int64 {
        Int64(y) * Int64(columns) + Int64(x)
    }
}
