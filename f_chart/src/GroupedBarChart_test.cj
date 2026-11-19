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
package fountain::f_chart

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*
import fountain::f_svg.SvgParser

@Test
public class GroupedBarChart_test {
    private func draw(json: String): String {
        GroupedBarChart().draw(JsonValue.fromStr(json).asObject())
    }

    private func count(svg: String, needle: String): Int64 {
        var total = 0
        var from = 0
        while (let Some(index) <- svg.indexOf(needle, from)) {
            total++
            from = index + needle.toArray().size
        }
        total
    }

    /** 2 个系列 × 3 个类目 = 6 根柱。 */
    @TestCase
    public func drawsSixBars(): Unit {
        let svg = draw("""
{
  "type": "grouped-bar",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "A", "data": [10, 20, 30] },
    { "name": "B", "data": [15, 25, 35] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 6)
    }

    /** 同一类目的两根柱不重叠，且间隔一个子槽。 */
    @TestCase
    public func groupedBarsDoNotOverlap(): Unit {
        let band = BandScale(0.0, 300.0, 3)
        let slot = band.bandWidth / 2.0
        let width = slot * 0.6
        let first = groupedBarX(band, 0, 0, 2, width)
        let second = groupedBarX(band, 0, 1, 2, width)
        @Assert(first + width <= second)
        @Assert(second - first - width > 0.0)
    }

    /** 每个系列一种颜色，图例展示两个系列。 */
    @TestCase
    public func drawsLegendAndColors(): Unit {
        let svg = draw("""
{
  "type": "grouped-bar",
  "theme": { "palette": ["#111111", "#222222"] },
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [1, 2] },
    { "name": "乙", "data": [2, 1] }
  ]
}
""")
        @Assert(count(svg, "class=\"legend-item\"") == 2)
        @Assert(svg.contains("fill=\"#111111\""))
        @Assert(svg.contains("fill=\"#222222\""))
    }

    /** 两个系列共享同一个数值轴。 */
    @TestCase
    public func sharesNumericAxis(): Unit {
        let svg = draw("""
{
  "type": "grouped-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "小", "data": [10] },
    { "name": "大", "data": [200] }
  ]
}
""")
        @Assert(svg.contains("200"))
    }

    /** null 跳过，其余柱正常。 */
    @TestCase
    public func skipsNullValues(): Unit {
        let svg = draw("""
{
  "type": "grouped-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [10, null] },
    { "name": "乙", "data": [20, 30] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 3)
    }

    /** type 不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 确定性。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "grouped-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [1, 2] },
    { "name": "乙", "data": [2, 1] }
  ]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 输出可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "grouped-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
