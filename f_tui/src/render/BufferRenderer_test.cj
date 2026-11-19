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

import fountain::f_tui.ansi.AnsiRenderer
import fountain::f_tui.term.{SizeProvider, TerminalWriter, TuiSize}
import ratatui_buffer.Buffer
import ratatui_core.{Position, Rect}
import ratatui_style.{Color, Modifier, Style}
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

class RenderWriter <: TerminalWriter {
    public var writes: ArrayList<String> = ArrayList<String>()
    public var flushes: Int64 = 0
    public var failAt: Int64 = -1

    public init() {}

    public func write(text: String): Bool {
        let index = writes.size
        writes.add(text)
        failAt < 0 || index != failAt
    }

    public func flush(): Bool {
        flushes += 1
        true
    }

    public func last(): String {
        if (writes.isEmpty()) {
            ""
        } else {
            writes[writes.size - 1]
        }
    }

    public func clear(): Unit {
        writes.clear()
        flushes = 0
        failAt = -1
    }
}

class FixedSizeProvider <: SizeProvider {
    public var value: Option<TuiSize>

    public init(size: TuiSize) {
        this.value = Some(size)
    }

    public func size(): Option<TuiSize> {
        value
    }
}

func textOf(haystack: String, needle: String): Int64 {
    match (haystack.indexOf(needle)) {
        case Some(index) => index
        case None => -1
    }
}

func styledBuffer(text: String, width: UInt16, height: UInt16, style: Style): Buffer {
    let buffer = Buffer.empty(Rect(0, 0, width, height))
    buffer.setString(0, 0, text, style)
    buffer
}

@Test
public class BufferRenderer_test {
    /** Buffer 单元格、颜色与修饰符翻译为 ANSI，一次 flush 只写一次。 */
    @TestCase
    public func drawTranslatesCellStyle(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(4, 2)))
        let style = Style().fg(Color.Red).bg(Color.Blue).addModifier(Modifier.BOLD)
        let buffer = styledBuffer("AB", 4, 2, style)

        renderer.draw(buffer)
        @Assert(renderer.flush())
        @Assert(writer.writes.size, 1)
        @Assert(writer.flushes, 1)
        let out = writer.last()
        @Assert(textOf(out, "AB") >= 0)
        @Assert(textOf(out, "38;5;1") >= 0)
        @Assert(textOf(out, "48;5;4") >= 0)
        @Assert(textOf(out, ";1m") >= 0)
        @Assert(textOf(out, "\u{1B}[1;1H") >= 0)
        @Assert(out.endsWith("\u{1B}[0m"))
    }

    /** 尺寸来自注入的 SizeProvider。 */
    @TestCase
    public func sizeComesFromProvider(): Unit {
        let renderer = BufferRenderer(AnsiRenderer(RenderWriter()), FixedSizeProvider(TuiSize(80, 24)))
        @Assert(renderer.size().width, 80)
        @Assert(renderer.size().height, 24)
    }

    /** 差分帧只重写变化行。 */
    @TestCase
    public func diffOnlyRewritesChangedRow(): Unit {
        let writer = RenderWriter()
        let size = FixedSizeProvider(TuiSize(4, 2))
        let renderer = BufferRenderer(AnsiRenderer(writer), size)
        let buffer = Buffer.empty(Rect(0, 0, 4, 2))
        buffer.setString(0, 0, "AB", Style())
        buffer.setString(0, 1, "CD", Style())
        renderer.draw(buffer)
        renderer.flush()

        writer.clear()
        buffer.setString(0, 1, "XY", Style())
        renderer.draw(buffer)
        renderer.flush()

        @Assert(writer.writes.size, 1)
        let out = writer.last()
        @Assert(textOf(out, "\u{1B}[2;1H") >= 0)
        @Assert(textOf(out, "XY") >= 0)
        @Assert(textOf(out, "\u{1B}[1;1H") < 0)
        @Assert(textOf(out, "AB") < 0)
    }

    /** 中文宽字符占两列，后续内容从第三列开始。 */
    @TestCase
    public func chineseWideCharacter(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(4, 1)))
        let buffer = Buffer.empty(Rect(0, 0, 4, 1))
        buffer.setString(0, 0, "中", Style())
        buffer.setString(2, 0, "x", Style())

        renderer.draw(buffer)
        renderer.flush()

        let out = writer.last()
        @Assert(textOf(out, "中x") >= 0)
    }

    /** Rgb 与 256 色索引都按对应 SGR 输出。 */
    @TestCase
    public func rgbAndIndexedColors(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(2, 1)))
        let buffer = Buffer.empty(Rect(0, 0, 2, 1))
        buffer.setString(0, 0, "a", Style().fg(Color.Rgb(10, 20, 30)))
        buffer.setString(1, 0, "b", Style().fg(Color.Indexed(200)))
        renderer.draw(buffer)
        renderer.flush()
        let out = writer.last()
        @Assert(textOf(out, "38;2;10;20;30") >= 0)
        @Assert(textOf(out, "38;5;200") >= 0)
    }

    /** clear 输出清屏序列并强制下一帧整屏。 */
    @TestCase
    public func clearEmitsClearScreen(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(2, 1)))
        let buffer = styledBuffer("x", 2, 1, Style())
        renderer.draw(buffer)
        renderer.flush()

        writer.clear()
        renderer.clear()
        @Assert(textOf(writer.last(), "\u{1B}[2J") >= 0)

        writer.clear()
        renderer.draw(buffer)
        renderer.flush()
        @Assert(textOf(writer.last(), "\u{1B}[2J") >= 0)
    }

    /** 光标位置翻译为 1 基 ANSI 定位。 */
    @TestCase
    public func cursorPosition(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(4, 4)))
        renderer.start()
        writer.clear()
        renderer.setCursor(Some(Position(1, 2)))
        renderer.draw(Buffer.empty(Rect(0, 0, 4, 4)))
        renderer.flush()
        let out = writer.last()
        @Assert(textOf(out, "\u{1B}[3;2H") >= 0)
        @Assert(textOf(out, "\u{1B}[?25h") >= 0)
    }

    /** 初始化进入备用屏并隐藏光标，恢复时退出。 */
    @TestCase
    public func initAndRestoreSequences(): Unit {
        let writer = RenderWriter()
        let renderer = BufferRenderer(AnsiRenderer(writer), FixedSizeProvider(TuiSize(2, 1)))
        renderer.start()
        @Assert(textOf(writer.writes[0], "\u{1B}[?1049h") >= 0)
        @Assert(textOf(writer.writes[1], "\u{1B}[?25l") >= 0)
        renderer.restore()
        let out = writer.last()
        @Assert(textOf(out, "\u{1B}[?25h") >= 0)
        @Assert(textOf(out, "\u{1B}[?1049l") >= 0)
    }
}
