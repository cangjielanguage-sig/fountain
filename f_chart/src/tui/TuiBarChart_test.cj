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

@Test
public class TuiBarChart_test {
    private func draw(json: String): String {
        TuiBarChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "bar",
  "title": "月度销售额",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["一月", "二月", "三月", "四月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "销售额", "data": [120, 200, 150, 180] }
  ]
}
"""

    /** 柱体、标题与类目标签。 */
    @TestCase
    public func drawsBars(): Unit {
        let svg = draw(sample)
        let plain = tuiStripAnsi(svg)
        @Assert(plain.contains("█"))
        @Assert(plain.contains("月度销售额"))
        @Assert(plain.contains("一月"))
        @Assert(plain.contains("四月"))
        @Assert(tuiPlainLines(svg).size == 18)
    }

    /** 系列颜色与 ANSI 复位。 */
    @TestCase
    public func usesSeriesColor(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[0m\n"))
    }

    /** 纵轴刻度包含数据范围。 */
    @TestCase
    public func drawsTicks(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("200"))
        @Assert(plain.contains("│"))
    }

    /** 负值不崩溃并保留 0 刻度。 */
    @TestCase
    public func handlesNegative(): Unit {
        let json = """
{
  "type": "bar",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [ { "name": "S", "data": [10, -5] } ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("0"))
        @Assert(plain.contains("█"))
    }

    /** null 跳过。 */
    @TestCase
    public func skipsNull(): Unit {
        let json = """
{
  "type": "bar",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [ { "name": "S", "data": [3, null, 5] } ]
}
"""
        @Assert(tuiStripAnsi(draw(json)).contains("█"))
    }

    /** 缺省尺寸为 80×24。 */
    @TestCase
    public func usesTuiDefaults(): Unit {
        let json = """
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [ { "name": "S", "data": [1] } ]
}
"""
        let lines = tuiPlainLines(draw(json))
        @Assert(lines.size == 24)
        @Assert(tuiDisplayWidth(lines[0]) == 80)
    }

    /** 数据长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        let json = """
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [ { "name": "S", "data": [1] } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{ "type": "bar", "xAxis": { "labels": ["A"] } }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "line", "series": [ { "name": "S", "data": [1] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 逐单元格结果与 ANSI 输出同形，并包含柱体字符。 */
    @TestCase
    public func drawCellsMatchesBarSymbols(): Unit {
        let chart = TuiBarChart()
        let cells = chart.drawCells(JsonValue.fromStr(sample).asObject())
        @Assert(cells.size, 18)
        var hasBlock = false
        for (row in cells) {
            @Assert(row.size, 60)
            for (cell in row) {
                if (cell == "█") {
                    hasBlock = true
                }
            }
        }
        @Assert(hasBlock)
        let plain = tuiStripAnsi(chart.draw(JsonValue.fromStr(sample).asObject()))
        var index = 0
        let lines = plain.split('\n')
        for (row in cells) {
            let joined = String.join(row, delimiter: "")
            while (index < lines.size && lines[index].isEmpty()) {
                index++
            }
            if (index < lines.size) {
                @Assert(joined, lines[index])
                index++
            }
        }
    }
}
