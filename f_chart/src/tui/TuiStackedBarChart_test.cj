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
public class TuiStackedBarChart_test {
    private func draw(json: String): String {
        TuiStackedBarChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "stacked-bar",
  "title": "各区收入构成",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "线上", "stack": "revenue", "data": [120, 90, 70] },
    { "name": "门店", "stack": "revenue", "data": [80, 70, 60] },
    { "name": "分销", "stack": "revenue", "data": [40, 35, 30] }
  ]
}
"""

    /** 三个系列在同一列堆叠。 */
    @TestCase
    public func drawsStackedBars(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[38;2;242;142;43m"))
        @Assert(svg.contains("\u{1B}[38;2;225;87;89m"))
        @Assert(tuiStripAnsi(svg).contains("█"))
        @Assert(tuiStripAnsi(svg).contains("▓"))
        @Assert(tuiStripAnsi(svg).contains("▒"))
    }

    /** 三个系列名进入图例。 */
    @TestCase
    public func drawsLegend(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("线上"))
        @Assert(plain.contains("门店"))
        @Assert(plain.contains("分销"))
    }

    /** 正负值分别向两侧堆叠。 */
    @TestCase
    public func handlesNegativeStack(): Unit {
        let json = """
{
  "type": "stacked-bar",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "正", "stack": "s", "data": [5] },
    { "name": "负", "stack": "s", "data": [-3] }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("█"))
        @Assert(plain.contains("0"))
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "grouped-bar", "series": [ { "name": "S", "data": [1] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
