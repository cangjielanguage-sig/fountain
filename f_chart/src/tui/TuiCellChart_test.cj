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
import fountain::f_chart.*
import fountain::f_data.json.*

/** `TuiCellChart`：逐单元格结果必须与 ANSI 输出逐字符一致。 */
@Test
public class TuiCellChart_test {
    private let sample: String = """
{
  "type": "line",
  "width": 40,
  "height": 12,
  "series": [ { "name": "cpu", "data": [1, 3, 2, 5, 4, 6] } ]
}
"""

    private func data(): JsonObject {
        JsonValue.fromStr(sample).asObject()
    }

    @TestCase
    public func lineCellsHaveFixedShape(): Unit {
        let cells = TuiLineChart().drawCells(data())
        @Assert(cells.size, 12)
        for (row in cells) {
            @Assert(row.size, 40)
            for (cell in row) {
                @Assert(!cell.contains('\u{1b}'))
            }
        }
    }

    /** 每行拼接后应等于 ANSI 输出去掉转义后的同一行。 */
    @TestCase
    public func lineCellsMatchAnsiLines(): Unit {
        let chart = TuiLineChart()
        let cells = chart.drawCells(data())
        let plain = tuiStripAnsi(chart.draw(data())).split('\n')
        var index = 0
        for (row in cells) {
            let joined = String.join(row, delimiter: "")
            while (index < plain.size && plain[index].isEmpty()) {
                index++
            }
            if (index < plain.size) {
                @Assert(joined, plain[index])
                index++
            }
        }
    }

    @TestCase
    public func tooSmallLineChartThrows(): Unit {
        let small = JsonValue.fromStr(
            '{"type":"line","width":10,"height":12,"series":[{"name":"s","data":[1,2]}]}').asObject()
        var threw = false
        try {
            TuiLineChart().drawCells(small)
        } catch (e: ChartException) {
            threw = true
            @Assert(e.kind, ChartErrorKind.InvalidValue)
        }
        @Assert(threw)
    }
}
