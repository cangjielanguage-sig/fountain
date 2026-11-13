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

import fountain::f_tui.term.TerminalWriter

/// 光标位置（0 基列 / 行）。
public struct CursorPos {
    /// 列。
    public var x: UInt16
    /// 行。
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        this.x = x
        this.y = y
    }
}

/// 把 `ScreenBuffer` 写成 ANSI 序列，并在帧之间做差分。
///
/// 一次 `render` 只调用一次 `TerminalWriter.write` 和一次 `flush`；
/// 写入失败后置为 broken，后续渲染不再尝试写终端。
public class AnsiRenderer {
    private let writer: TerminalWriter
    private var previous: Option<ScreenBuffer> = None
    private var cursor: ?CursorPos = None
    private var cursorVisible: Bool = true
    private var altActive: Bool = false
    private var broken: Bool = false

    public init(writer: TerminalWriter) {
        this.writer = writer
    }

    /// 是否已因写失败停止渲染。
    public func isBroken(): Bool {
        broken
    }

    /// 进入备用屏。
    public func enterAltScreen(): Bool {
        if (altActive) {
            return !broken
        }
        altActive = true
        emit(AnsiSequence.ENTER_ALT_SCREEN)
    }

    /// 退出备用屏。
    public func exitAltScreen(): Bool {
        if (!altActive) {
            return !broken
        }
        altActive = false
        previous = None
        emit(AnsiSequence.EXIT_ALT_SCREEN)
    }

    /// 隐藏光标。
    public func hideCursor(): Bool {
        if (!cursorVisible) {
            return !broken
        }
        cursorVisible = false
        emit(AnsiSequence.HIDE_CURSOR)
    }

    /// 显示光标。
    public func showCursor(): Bool {
        if (cursorVisible) {
            return !broken
        }
        cursorVisible = true
        emit(AnsiSequence.SHOW_CURSOR)
    }

    /// 清屏并丢弃上一帧，下一次绘制整屏。
    public func clear(): Bool {
        previous = None
        emit(AnsiSequence.CLEAR_SCREEN + AnsiSequence.RESET_STYLE)
    }

    /// 设置帧尾光标位置；`None` 表示不显示光标。
    public func setCursor(position: ?CursorPos): Unit {
        cursor = position
    }

    /// 恢复正常终端状态：显示光标、退出备用屏、复位样式。
    public func reset(): Unit {
        if (broken) {
            cursorVisible = true
            altActive = false
            previous = None
            cursor = None
            return
        }
        let builder = StringBuilder()
        if (!cursorVisible) {
            builder.append(AnsiSequence.SHOW_CURSOR)
            cursorVisible = true
        }
        if (altActive) {
            builder.append(AnsiSequence.EXIT_ALT_SCREEN)
            altActive = false
        }
        builder.append(AnsiSequence.RESET_STYLE)
        previous = None
        cursor = None
        emit(builder.toString())
    }

    /// 渲染一帧。`forceFull` 为真或尺寸变化时整屏重绘，否则只写变化单元格。
    public func render(frame: ScreenBuffer, forceFull: Bool): Bool {
        if (broken) {
            return false
        }
        var full = forceFull
        if (!full) {
            full = match (previous) {
                case Some(old) => old.width() != frame.width() || old.height() != frame.height()
                case None => true
            }
        }
        let builder = StringBuilder()
        if (full) {
            builder.append(AnsiSequence.CLEAR_SCREEN)
        }
        var lastStyle = ""
        var hasOutput = full
        var y: UInt16 = 0
        while (y < frame.height()) {
            var x: UInt16 = 0
            while (x < frame.width()) {
                let current = frame.get(x, y)
                let changed = if (full) {
                    !current.skip
                } else {
                    !current.skip && !sameAsPrevious(current, x, y)
                }
                if (!changed) {
                    x += 1
                    continue
                }
                builder.append(AnsiSequence.cursorTo(x, y))
                hasOutput = true
                while (x < frame.width()) {
                    let cell = frame.get(x, y)
                    if (cell.skip) {
                        x += 1
                        continue
                    }
                    if (!full && sameAsPrevious(cell, x, y)) {
                        break
                    }
                    let style = AnsiSequence.styleFor(cell)
                    if (style != lastStyle) {
                        builder.append(style)
                        lastStyle = style
                    }
                    builder.append(cell.symbol)
                    x += 1
                }
            }
            y += 1
        }
        match (cursor) {
            case Some(position) =>
                builder.append(AnsiSequence.cursorTo(position.x, position.y))
                if (!cursorVisible) {
                    builder.append(AnsiSequence.SHOW_CURSOR)
                    cursorVisible = true
                }
                hasOutput = true
            case None =>
                if (cursorVisible) {
                    builder.append(AnsiSequence.HIDE_CURSOR)
                    cursorVisible = false
                    hasOutput = true
                }
        }
        if (lastStyle != "") {
            builder.append(AnsiSequence.RESET_STYLE)
        }
        previous = Some(frame.clone())
        if (!hasOutput) {
            return true
        }
        emit(builder.toString())
    }

    private func sameAsPrevious(cell: ScreenCell, x: UInt16, y: UInt16): Bool {
        match (previous) {
            case Some(old) => cell.equals(old.get(x, y))
            case None => false
        }
    }

    private func emit(text: String): Bool {
        if (broken) {
            return false
        }
        if (!writer.write(text)) {
            broken = true
            return false
        }
        if (!writer.flush()) {
            broken = true
            return false
        }
        true
    }
}
