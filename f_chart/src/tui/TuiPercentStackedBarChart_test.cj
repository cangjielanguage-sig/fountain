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
public class TuiPercentStackedBarChart_test {
    private func draw(json: String): String {
        TuiPercentStackedBarChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "percent-stacked-bar",
  "title": "各渠道占比",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "series": [
    { "name": "线上", "data": [60, 70, 80] },
    { "name": "门店", "data": [30, 20, 15] },
    { "name": "分销", "data": [10, 10, 5] }
  ]
}
"""

    /** 三种颜色都出现，柱体存在。 */
    @TestCase
    public func drawsPercentBars(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[38;2;242;142;43m"))
        @Assert(svg.contains("\u{1B}[38;2;225;87;89m"))
        @Assert(tuiStripAnsi(svg).contains("█"))
    }

    /** 纵轴为 0–100。 */
    @TestCase
    public func usesPercentAxis(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("100"))
        @Assert(plain.contains("20"))
    }

    /** 零和类目不画柱。 */
    @TestCase
    public func skipsZeroTotal(): Unit {
        let json = """
{
  "type": "percent-stacked-bar",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "X", "data": [10, 0] },
    { "name": "Y", "data": [10, 0] }
  ]
}
"""
        @Assert(tuiStripAnsi(draw(json)).contains("█"))
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "stacked-bar", "series": [ { "name": "S", "data": [1] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
