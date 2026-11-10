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

import std.collection.ArrayList

/// 加粗。
public const MODIFIER_BOLD: Int64 = 0x0001
/// 变暗。
public const MODIFIER_DIM: Int64 = 0x0002
/// 斜体。
public const MODIFIER_ITALIC: Int64 = 0x0004
/// 下划线。
public const MODIFIER_UNDERLINE: Int64 = 0x0008
/// 慢速闪烁。
public const MODIFIER_SLOW_BLINK: Int64 = 0x0010
/// 快速闪烁。
public const MODIFIER_RAPID_BLINK: Int64 = 0x0020
/// 反显。
public const MODIFIER_REVERSED: Int64 = 0x0040
/// 隐藏。
public const MODIFIER_HIDDEN: Int64 = 0x0080
/// 删除线。
public const MODIFIER_CROSSED_OUT: Int64 = 0x0100

/// ANSI 颜色描述。`ansi` 包不依赖 ratatui，颜色由 `render` 包翻译后传入。
public struct AnsiColor {
    /// 0 = 终端默认色，1 = 256 色索引，2 = RGB。
    public var kind: Int64
    /// 256 色索引。
    public var index: UInt8
    /// RGB 红分量。
    public var red: UInt8
    /// RGB 绿分量。
    public var green: UInt8
    /// RGB 蓝分量。
    public var blue: UInt8

    public init(kind!: Int64, index!: UInt8, red!: UInt8, green!: UInt8, blue!: UInt8) {
        this.kind = kind
        this.index = index
        this.red = red
        this.green = green
        this.blue = blue
    }

    /// 终端默认色。
    public static let Default: AnsiColor = AnsiColor(kind: 0, index: 0, red: 0, green: 0, blue: 0)

    /// 256 色索引。
    public static func indexed(value: UInt8): AnsiColor {
        AnsiColor(kind: 1, index: value, red: 0, green: 0, blue: 0)
    }

    /// 24 位真彩色。
    public static func rgb(r: UInt8, g: UInt8, b: UInt8): AnsiColor {
        AnsiColor(kind: 2, index: 0, red: r, green: g, blue: b)
    }

    /// 是否使用终端默认色。
    public func isDefault(): Bool {
        kind == 0
    }

    /// 前景色 SGR 参数；默认色返回空串。
    public func foregroundParams(): String {
        match (kind) {
            case 1 => "38;5;${index}"
            case 2 => "38;2;${red};${green};${blue}"
            case _ => ""
        }
    }

    /// 背景色 SGR 参数；默认色返回空串。
    public func backgroundParams(): String {
        match (kind) {
            case 1 => "48;5;${index}"
            case 2 => "48;2;${red};${green};${blue}"
            case _ => ""
        }
    }

    public func equals(other: AnsiColor): Bool {
        kind == other.kind && index == other.index && red == other.red && green == other.green &&
            blue == other.blue
    }
}

/// 固定 ANSI 序列与 SGR 拼装。
public class AnsiSequence {
    /// ESC 字符。
    public static const ESC: String = "\u{1B}"

    /// 进入备用屏。
    public static const ENTER_ALT_SCREEN: String = "\u{1B}[?1049h"
    /// 退出备用屏。
    public static const EXIT_ALT_SCREEN: String = "\u{1B}[?1049l"
    /// 隐藏光标。
    public static const HIDE_CURSOR: String = "\u{1B}[?25l"
    /// 显示光标。
    public static const SHOW_CURSOR: String = "\u{1B}[?25h"
    /// 清屏并回到左上角。
    public static const CLEAR_SCREEN: String = "\u{1B}[2J"
    /// 复位所有 SGR 属性。
    public static const RESET_STYLE: String = "\u{1B}[0m"

    /// 光标定位（1 基行列）。
    public static func cursorTo(x: UInt16, y: UInt16): String {
        "${ESC}[${Int64(y) + 1};${Int64(x) + 1}H"
    }

    /// 由单元格颜色与修饰符生成完整 SGR 序列（先复位再设置）。
    public static func styleFor(cell: ScreenCell): String {
        let params = ArrayList<String>()
        if (!cell.fg.isDefault()) {
            params.add(cell.fg.foregroundParams())
        }
        if (!cell.bg.isDefault()) {
            params.add(cell.bg.backgroundParams())
        }
        appendModifier(params, cell.modifier, MODIFIER_BOLD, "1")
        appendModifier(params, cell.modifier, MODIFIER_DIM, "2")
        appendModifier(params, cell.modifier, MODIFIER_ITALIC, "3")
        appendModifier(params, cell.modifier, MODIFIER_UNDERLINE, "4")
        appendModifier(params, cell.modifier, MODIFIER_SLOW_BLINK, "5")
        appendModifier(params, cell.modifier, MODIFIER_RAPID_BLINK, "6")
        appendModifier(params, cell.modifier, MODIFIER_REVERSED, "7")
        appendModifier(params, cell.modifier, MODIFIER_HIDDEN, "8")
        appendModifier(params, cell.modifier, MODIFIER_CROSSED_OUT, "9")
        if (params.isEmpty()) {
            return RESET_STYLE
        }
        let builder = StringBuilder()
        builder.append(ESC)
        builder.append("[0")
        for (param in params) {
            builder.append(";")
            builder.append(param)
        }
        builder.append("m")
        builder.toString()
    }

    private static func appendModifier(params: ArrayList<String>, value: Int64, flag: Int64,
        code: String): Unit {
        if ((value & flag) != 0) {
            params.add(code)
        }
    }
}
