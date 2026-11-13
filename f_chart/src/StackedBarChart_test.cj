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
public class StackedBarChart_test {
    private func draw(json: String): String {
        StackedBarChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 2 系列 × 3 类目 = 6 段。 */
    @TestCase
    public func drawsSixSegments(): Unit {
        let svg = draw("""
{
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "上", "data": [10, 20, 30] },
    { "name": "下", "data": [5, 15, 25] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 6)
    }

    /** 同类目的段共用 x。 */
    @TestCase
    public func segmentsShareX(): Unit {
        let band = BandScale(0.0, 300.0, 3)
        let first = stackedBarX(band, 0, 30.0)
        let second = stackedBarX(band, 0, 30.0)
        @Assert(first == second)
        @Assert(first == band.center(0) - 15.0)
    }

    /** y 轴上界覆盖类目总和。 */
    @TestCase
    public func rangeCoversCategoryTotals(): Unit {
        let svg = draw("""
{
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "甲", "data": [60, 50] },
    { "name": "乙", "data": [40, 30] }
  ]
}
""")
        @Assert(svg.contains("100"))
    }

    /** null 段跳过。 */
    @TestCase
    public func skipsNullValues(): Unit {
        let svg = draw("""
{
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [10, null] },
    { "name": "乙", "data": [20, 30] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 3)
    }

    /** 负值段带标记。 */
    @TestCase
    public func marksNegativeSegments(): Unit {
        let svg = draw("""
{
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "正", "data": [30] },
    { "name": "负", "data": [-10] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar bar-negative\"") == 1)
    }

    /** type 不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "grouped-bar",
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
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [1, 2] },
    { "name": "乙", "data": [2, 1] }
  ]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可被 f_svg 解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "stacked-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
