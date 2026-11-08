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
public class HorizontalBarChart_test {
    private func draw(json: String): String {
        HorizontalBarChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 五个类别五根柱。 */
    @TestCase
    public func drawsFiveBars(): Unit {
        let svg = draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear", "min": 0 },
  "yAxis": { "type": "category", "labels": ["上海", "北京", "深圳", "广州", "杭州"] },
  "series": [{ "name": "销售额", "data": [320, 290, 260, 210, 180] }]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 5)
        @Assert(svg.contains("上海"))
        @Assert(svg.contains("杭州"))
    }

    /** 数值 x 轴刻度。 */
    @TestCase
    public func drawsNumericXAxis(): Unit {
        let svg = draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear", "min": 0, "max": 300 },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "值", "data": [100, 200] }]
}
""")
        @Assert(count(svg, "class=\"tick-label\"") >= 2)
    }

    /** 负值柱。 */
    @TestCase
    public func marksNegativeBars(): Unit {
        let svg = draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["降", "升"] },
  "series": [{ "name": "变化", "data": [-10, 20] }]
}
""")
        @Assert(count(svg, "class=\"bar bar-negative\"") == 1)
    }

    /** null 跳过。 */
    @TestCase
    public func skipsNullValues(): Unit {
        let svg = draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "值", "data": [10, null, 30] }]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 2)
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] }
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 确定性。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear", "min": 0 },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "值", "data": [1, 2] }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "horizontal-bar",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "值", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
