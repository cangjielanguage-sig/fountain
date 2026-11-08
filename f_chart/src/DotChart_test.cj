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
public class DotChart_test {
    private func draw(json: String): String {
        DotChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三个点、三条 stem。 */
    @TestCase
    public func drawsDotsAndStems(): Unit {
        let svg = draw("""
{
  "type": "dot",
  "xAxis": { "type": "linear", "min": 0 },
  "yAxis": { "type": "category", "labels": ["内科", "外科", "儿科"] },
  "series": [{ "name": "满意度", "data": [88, 82, 91] }]
}
""")
        @Assert(count(svg, "class=\"dot\"") == 3)
        @Assert(count(svg, "class=\"stem\"") == 3)
        @Assert(svg.contains("内科"))
    }

    /** null 跳过。 */
    @TestCase
    public func skipsNullValues(): Unit {
        let svg = draw("""
{
  "type": "dot",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "值", "data": [10, null, 30] }]
}
""")
        @Assert(count(svg, "class=\"dot\"") == 2)
    }

    /** 自定义颜色。 */
    @TestCase
    public func usesSeriesColor(): Unit {
        let svg = draw("""
{
  "type": "dot",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "值", "data": [10], "color": "#abcdef" }]
}
""")
        @Assert(svg.contains("fill=\"#abcdef\""))
        @Assert(svg.contains("stroke=\"#abcdef\""))
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "horizontal-bar",
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
  "type": "dot",
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
  "type": "dot",
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
  "type": "dot",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "值", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
