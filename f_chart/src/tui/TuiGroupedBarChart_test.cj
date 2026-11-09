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
public class TuiGroupedBarChart_test {
    private func draw(json: String): String {
        TuiGroupedBarChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "grouped-bar",
  "title": "各季度产品销售额",
  "width": 64,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "产品 A", "data": [120, 150, 170, 160] },
    { "name": "产品 B", "data": [90, 110, 130, 140] }
  ]
}
"""

    /** 两个系列并排，颜色可区分。 */
    @TestCase
    public func drawsGroupedBars(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[38;2;242;142;43m"))
        @Assert(tuiStripAnsi(svg).contains("█"))
    }

    /** 图例包含两个系列。 */
    @TestCase
    public func drawsLegend(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("产品 A"))
        @Assert(plain.contains("产品 B"))
        @Assert(plain.contains("■"))
    }

    /** 同一行存在两段不同颜色的柱体。 */
    @TestCase
    public func placesBarsSideBySide(): Unit {
        let svg = draw(sample)
        var found = false
        for (line in svg.split("\n")) {
            if (line.contains("\u{1B}[38;2;78;121;167m") &&
                line.contains("\u{1B}[38;2;242;142;43m")) {
                found = true
                break
            }
        }
        @Assert(found)
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "bar", "series": [ { "name": "S", "data": [1] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
