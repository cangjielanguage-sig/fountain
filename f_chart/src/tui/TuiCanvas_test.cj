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

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class TuiCanvas_test {
    /** 文本写入指定行列。 */
    @TestCase
    public func writesText(): Unit {
        let canvas = TuiCanvas(10, 3)
        canvas.putText(1, 1, "AB", "#ff0000")
        let lines = canvas.plainLines()
        @Assert(lines.size == 3)
        @Assert(lines[1].startsWith(" AB"))
    }

    /** CJK 字符占两列。 */
    @TestCase
    public func countsCjkWidth(): Unit {
        let canvas = TuiCanvas(10, 1)
        canvas.putText(0, 0, "中文", "#000000")
        let lines = canvas.plainLines()
        @Assert(lines[0].contains("中文"))
        @Assert(tuiDisplayWidth(lines[0]) == 10)
    }

    /** 超出宽度的文本截断并补省略号。 */
    @TestCase
    public func truncatesText(): Unit {
        let canvas = TuiCanvas(6, 1)
        canvas.putText(0, 0, "abcdefgh", "#000000")
        let line = canvas.plainLines()[0]
        @Assert(line.startsWith("abcde…"))
        @Assert(tuiDisplayWidth(line) == 6)
    }

    /** 横向线段覆盖连续的列。 */
    @TestCase
    public func drawsLine(): Unit {
        let canvas = TuiCanvas(8, 1)
        canvas.drawLine(0, 0, 4, 0, "*", "#000000")
        @Assert(canvas.plainLines()[0].startsWith("*****"))
    }

    /** 渲染输出每行以复位和换行结束。 */
    @TestCase
    public func rendersAnsiRows(): Unit {
        let canvas = TuiCanvas(4, 2)
        canvas.putText(0, 0, "AB", "#ff0000")
        let output = canvas.render()
        @Assert(output.contains("\u{1B}[38;2;255;0;0m"))
        @Assert(output.contains("\u{1B}[0m\n"))
        @Assert(output.split("\n").size == 3)
    }

    /** 纯文本行数与画布高度一致。 */
    @TestCase
    public func keepsDimensions(): Unit {
        let canvas = TuiCanvas(12, 5)
        @Assert(canvas.plainLines().size == 5)
        for (line in canvas.plainLines()) {
            @Assert(tuiDisplayWidth(line) == 12)
        }
    }

    /** 居中与右对齐。 */
    @TestCase
    public func alignsText(): Unit {
        let center = TuiCanvas(10, 1)
        center.putText(0, 0, "AB", "#000000", align: "middle")
        @Assert(center.plainLines()[0].startsWith("    AB"))
        let end = TuiCanvas(10, 1)
        end.putText(0, 0, "AB", "#000000", align: "end")
        @Assert(end.plainLines()[0].startsWith("        AB"))
    }

    /** 显示宽度：CJK 2 列，ASCII 1 列。 */
    @TestCase
    public func measuresWidth(): Unit {
        @Assert(tuiDisplayWidth("abc") == 3)
        @Assert(tuiDisplayWidth("中文") == 4)
        @Assert(tuiDisplayWidth("a中b") == 4)
    }

    /** 逐单元格符号：列数固定，宽字符后半格为空串。 */
    @TestCase
    public func cellSymbolsMarksContinuation(): Unit {
        let canvas = TuiCanvas(3, 2)
        canvas.putText(0, 0, "A中", "#000000")
        canvas.set(2, 1, "Z", "#000000")
        let cells = canvas.cellSymbols()
        @Assert(cells.size, 2)
        @Assert(cells[0].size, 3)
        @Assert(cells[0][0], "A")
        @Assert(cells[0][1], "中")
        @Assert(cells[0][2], "")
        @Assert(cells[1][0], " ")
        @Assert(cells[1][2], "Z")
    }
}
