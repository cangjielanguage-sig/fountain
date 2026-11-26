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
package fountain::f_tui.render

import fountain::f_tui.ansi.{AnsiColor, AnsiRenderer, CursorPos, ScreenBuffer, ScreenCell, displayWidth, sanitizeSymbol}
import fountain::f_tui.term.{SizeProvider, TuiSize}
import ratatui_buffer.Buffer
import ratatui_core.Position
import ratatui_style.{Color, Modifier}

/// 把 `ratatui_buffer.Buffer` 翻译为 ANSI 帧并做差分输出。
///
/// 只使用 ratatui 基础类型，不实现 `ratatui_backend.Backend`，
/// 不承担布局与组件逻辑；绘制内容由宿主构造的 `Buffer` 决定。
public class BufferRenderer {
    private let renderer: AnsiRenderer
    private let sizeProvider: SizeProvider
    private var frame: ScreenBuffer = ScreenBuffer(0, 0)
    private var cursor: ?CursorPos = None
    private var lastSize: TuiSize = TuiSize(0, 0)

    public init(renderer: AnsiRenderer, sizeProvider: SizeProvider) {
        this.renderer = renderer
        this.sizeProvider = sizeProvider
    }

    /// 进入备用屏并隐藏光标。
    public func start(): Bool {
        let entered = renderer.enterAltScreen()
        let hidden = renderer.hideCursor()
        entered && hidden
    }

    /// 恢复正常终端状态。
    public func restore(): Unit {
        renderer.reset()
    }

    /// 是否已因写失败停止渲染。
    public func isBroken(): Bool {
        renderer.isBroken()
    }

    /// 终端尺寸；未知时返回最近一次成功读取或 `0x0`。
    public func size(): TuiSize {
        match (sizeProvider.size()) {
            case Some(value) => lastSize = value
            case None => ()
        }
        lastSize
    }

    /// 清屏并丢弃上一帧。
    public func clear(): Unit {
        renderer.clear()
    }

    /// 设置刷新时的光标位置；`None` 隐藏光标。
    public func setCursor(position: ?Position): Unit {
        cursor = match (position) {
            case Some(value) => Some(CursorPos(value.x, value.y))
            case None => None
        }
    }

    /// 把 `Buffer` 内容复制到内部帧缓冲。
    public func draw(buffer: Buffer): Unit {
        var width = size().width
        var height = size().height
        if (width == 0 || height == 0) {
            width = buffer.area.width
            height = buffer.area.height
        }
        if (width == 0 || height == 0) {
            return
        }
        let next = ScreenBuffer(width, height)
        var y: UInt16 = 0
        while (y < height) {
            var skipped = false
            var x: UInt16 = 0
            while (x < width) {
                if (skipped) {
                    skipped = false
                    x += 1
                    continue
                }
                let sourceX = buffer.area.x + x
                let sourceY = buffer.area.y + y
                if (sourceX < buffer.area.right() && sourceY < buffer.area.bottom()) {
                    let source = buffer.get(sourceX, sourceY)
                    let symbol = sanitizeSymbol(source.symbol())
                    next.set(x, y, ScreenCell(symbol, fg: toAnsiColor(source.fg),
                        bg: toAnsiColor(source.bg), modifier: source.modifier.bits))
                    if (displayWidth(symbol) >= 2) {
                        skipped = true
                    }
                }
                x += 1
            }
            y += 1
        }
        frame = next
    }

    /// 输出当前帧与上一帧的差异；一次刷新只写一次终端。
    public func flush(): Bool {
        renderer.setCursor(cursor)
        renderer.render(frame, false)
    }

    private func toAnsiColor(value: Color): AnsiColor {
        match (value) {
            case Color.Reset => AnsiColor.Default
            case Color.Black => AnsiColor.indexed(0)
            case Color.Red => AnsiColor.indexed(1)
            case Color.Green => AnsiColor.indexed(2)
            case Color.Yellow => AnsiColor.indexed(3)
            case Color.Blue => AnsiColor.indexed(4)
            case Color.Magenta => AnsiColor.indexed(5)
            case Color.Cyan => AnsiColor.indexed(6)
            case Color.Gray => AnsiColor.indexed(7)
            case Color.DarkGray => AnsiColor.indexed(8)
            case Color.LightRed => AnsiColor.indexed(9)
            case Color.LightGreen => AnsiColor.indexed(10)
            case Color.LightYellow => AnsiColor.indexed(11)
            case Color.LightBlue => AnsiColor.indexed(12)
            case Color.LightMagenta => AnsiColor.indexed(13)
            case Color.LightCyan => AnsiColor.indexed(14)
            case Color.White => AnsiColor.indexed(15)
            case Color.Rgb(r, g, b) => AnsiColor.rgb(r, g, b)
            case Color.Indexed(index) => AnsiColor.indexed(index)
        }
    }
}
