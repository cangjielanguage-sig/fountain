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
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/// 记录写入内容、可注入失败的假 writer。
class RecordingWriter <: TerminalWriter {
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

func cell(symbol: String): ScreenCell {
    ScreenCell(symbol)
}

func indexOf(haystack: String, needle: String): Int64 {
    match (haystack.indexOf(needle)) {
        case Some(index) => index
        case None => -1
    }
}

@Test
public class AnsiRenderer_test {
    /** 备用屏进出与光标显隐使用固定序列。 */
    @TestCase
    public func alternateScreenAndCursor(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        renderer.enterAltScreen()
        renderer.hideCursor()
        renderer.showCursor()
        renderer.exitAltScreen()

        @Assert(writer.writes.size, 4)
        @Assert(indexOf(writer.writes[0], "\u{1B}[?1049h") >= 0)
        @Assert(indexOf(writer.writes[1], "\u{1B}[?25l") >= 0)
        @Assert(indexOf(writer.writes[2], "\u{1B}[?25h") >= 0)
        @Assert(indexOf(writer.writes[3], "\u{1B}[?1049l") >= 0)
    }

    /** 首次绘制整屏：清屏、逐行定位、一次 write、一次 flush、末尾复位。 */
    @TestCase
    public func fullFrameWritesRows(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(3, 2)
        frame.set(0, 0, cell("a"))
        frame.set(1, 0, cell("b"))
        frame.set(0, 1, cell("c"))

        @Assert(renderer.render(frame, false))
        @Assert(writer.writes.size, 1)
        @Assert(writer.flushes, 1)
        let out = writer.last()
        @Assert(indexOf(out, "\u{1B}[2J") >= 0)
        @Assert(indexOf(out, "\u{1B}[1;1H") >= 0)
        @Assert(indexOf(out, "ab") >= 0)
        @Assert(indexOf(out, "\u{1B}[2;1H") >= 0)
        @Assert(indexOf(out, "c") >= 0)
        @Assert(out.endsWith("\u{1B}[0m"))
    }

    /** 差分帧只重写变化行，不发整屏。 */
    @TestCase
    public func diffOnlyTouchesChangedRow(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(3, 2)
        frame.set(0, 0, cell("a"))
        frame.set(1, 0, cell("b"))
        frame.set(0, 1, cell("c"))
        renderer.render(frame, false)

        writer.clear()
        frame.set(0, 1, cell("Z"))
        @Assert(renderer.render(frame, false))
        @Assert(writer.writes.size, 1)
        let out = writer.last()
        @Assert(indexOf(out, "\u{1B}[2;1H") >= 0)
        @Assert(indexOf(out, "Z") >= 0)
        @Assert(indexOf(out, "\u{1B}[1;1H") < 0)
        @Assert(indexOf(out, "ab") < 0)
        @Assert(indexOf(out, "\u{1B}[2J") < 0)
    }

    /** 未变化的帧不产生任何写入。 */
    @TestCase
    public func unchangedFrameWritesNothing(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(2, 1)
        frame.set(0, 0, cell("x"))
        renderer.render(frame, false)
        writer.clear()
        @Assert(renderer.render(frame, false))
        @Assert(writer.writes.isEmpty())
    }

    /** 宽字符占两列，后一列标记为 skip 且不重复输出。 */
    @TestCase
    public func wideRuneOccupiesTwoColumns(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(4, 1)
        frame.set(0, 0, cell("中"))
        frame.set(2, 0, cell("x"))
        @Assert(frame.get(1, 0).skip)
        @Assert(frame.get(1, 0).symbol, "")

        renderer.render(frame, false)
        let out = writer.last()
        @Assert(indexOf(out, "中x") >= 0)
    }

    /** 业务数据中的控制字符在写入终端前被替换。 */
    @TestCase
    public func controlCharactersAreReplaced(): Unit {
        let frame = ScreenBuffer(8, 1)
        frame.set(0, 0, cell("a\u{1B}[31mb"))
        @Assert(frame.get(0, 0).symbol, "a?[31mb")

        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        renderer.render(frame, false)
        let out = writer.last()
        @Assert(indexOf(out, "a?[31mb") >= 0)
        @Assert(indexOf(out, "a\u{1B}[31mb") < 0)
    }

    /** SGR 序列包含前景、背景与修饰符。 */
    @TestCase
    public func styleSequences(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(1, 1)
        frame.set(0, 0, ScreenCell("x", fg: AnsiColor.indexed(1),
            bg: AnsiColor.rgb(10, 20, 30), modifier: MODIFIER_BOLD | MODIFIER_UNDERLINE))
        renderer.render(frame, false)
        let out = writer.last()
        @Assert(indexOf(out, "38;5;1") >= 0)
        @Assert(indexOf(out, "48;2;10;20;30") >= 0)
        @Assert(indexOf(out, "1;4m") >= 0)
    }

    /** 写失败后标记不可用，后续渲染不再尝试写。 */
    @TestCase
    public func writeFailureDisablesRenderer(): Unit {
        let writer = RecordingWriter()
        writer.failAt = 0
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(2, 1)
        frame.set(0, 0, cell("x"))
        @Assert(renderer.render(frame, false), false)
        @Assert(renderer.isBroken())
        @Assert(writer.writes.size, 1)

        @Assert(renderer.render(frame, false), false)
        @Assert(writer.writes.size, 1)
    }

    /** 尺寸变化后强制整屏重绘。 */
    @TestCase
    public func resizeForcesFullRedraw(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        renderer.render(ScreenBuffer(2, 2), false)
        writer.clear()
        renderer.render(ScreenBuffer(3, 2), false)
        let out = writer.last()
        @Assert(indexOf(out, "\u{1B}[2J") >= 0)
    }

    /** 光标定位在帧尾输出，位置按 1 基行列。 */
    @TestCase
    public func cursorPositionIsEmitted(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        renderer.hideCursor()
        writer.clear()
        renderer.setCursor(Some(CursorPos(2, 3)))
        renderer.render(ScreenBuffer(4, 4), false)
        let out = writer.last()
        @Assert(indexOf(out, "\u{1B}[4;3H") >= 0)
        @Assert(indexOf(out, "\u{1B}[?25h") >= 0)
    }

    /** 清屏重置上一帧，下一次绘制整屏。 */
    @TestCase
    public func clearResetsFrame(): Unit {
        let writer = RecordingWriter()
        let renderer = AnsiRenderer(writer)
        let frame = ScreenBuffer(2, 1)
        frame.set(0, 0, cell("x"))
        renderer.render(frame, false)
        writer.clear()
        renderer.clear()
        @Assert(indexOf(writer.last(), "\u{1B}[2J") >= 0)
        writer.clear()
        renderer.render(frame, false)
        @Assert(indexOf(writer.last(), "\u{1B}[2J") >= 0)
    }
}
