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
public class ComboChart_test {
    private func draw(json: String): String {
        ComboChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 柱 + 线。 */
    @TestCase
    public func drawsBarAndLine(): Unit {
        let svg = draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "销量", "type": "bar", "data": [120, 150, 130, 170] },
    { "name": "趋势", "type": "line", "data": [110, 140, 145, 160] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 4)
        @Assert(count(svg, "class=\"line\"") == 1)
    }

    /** 柱 + 线 + 点。 */
    @TestCase
    public func drawsThreeKinds(): Unit {
        let svg = draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "销量", "type": "bar", "data": [120, 150, 130, 170] },
    { "name": "趋势", "type": "line", "data": [110, 140, 145, 160] },
    { "name": "异常", "type": "scatter", "data": [{ "x": "2月", "y": 180 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 4)
        @Assert(count(svg, "class=\"line\"") == 1)
        @Assert(count(svg, "class=\"symbol\"") == 1)
    }

    /** 右侧轴。 */
    @TestCase
    public func drawsRightAxis(): Unit {
        let svg = draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2"] },
  "yAxis": { "type": "linear", "min": 0 },
  "yAxis2": { "type": "linear", "min": 0, "max": 50, "labelFormat": "{value}%" },
  "series": [
    { "name": "销量", "type": "bar", "data": [120, 150] },
    { "name": "增长率", "type": "line", "axis": "right", "data": [18, 22] }
  ]
}
""")
        @Assert(svg.contains("50%"))
    }

    /** 堆叠组。 */
    @TestCase
    public func stacksGroupedBars(): Unit {
        let svg = draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "上", "type": "stacked-bar", "stack": "s", "data": [10, 20] },
    { "name": "下", "type": "stacked-bar", "stack": "s", "data": [5, 15] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 4)
    }

    /** 未知系列类型。 */
    @TestCase
    public func rejectsUnknownSeriesType(): Unit {
        try {
            draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "面积", "type": "area", "data": [1] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "type": "bar", "data": [1] }]
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
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "柱", "type": "bar", "data": [1, 2] },
    { "name": "线", "type": "line", "data": [2, 1] }
  ]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "柱", "type": "bar", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
