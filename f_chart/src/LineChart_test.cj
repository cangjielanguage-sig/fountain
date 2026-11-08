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
public class LineChart_test {
    private func draw(json: String): String {
        LineChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 类目折线：一条路径、三个符号。 */
    @TestCase
    public func drawsCategoryLine(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月"] },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "趋势", "data": [10, 20, 15] }]
}
""")
        @Assert(count(svg, "class=\"line\"") == 1)
        @Assert(count(svg, "class=\"symbol\"") == 3)
    }

    /** null 断开成两条路径。 */
    @TestCase
    public func breaksOnNull(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D", "E"] },
  "series": [{ "name": "趋势", "data": [1, 2, null, 4, 5] }]
}
""")
        @Assert(count(svg, "class=\"line\"") == 2)
        @Assert(count(svg, "class=\"symbol\"") == 4)
    }

    /** 数值 XY 轴。 */
    @TestCase
    public func drawsNumericXY(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "linear", "title": "x" },
  "yAxis": { "type": "linear", "title": "y" },
  "series": [
    { "name": "样本", "data": [{ "x": 0, "y": 1 }, { "x": 10, "y": 5 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"symbol\"") == 2)
        @Assert(svg.contains(">0<") || svg.contains(">10<"))
    }

    /** 时间轴接受 YYYY-MM-DD 并格式化刻度。 */
    @TestCase
    public func drawsTimeAxis(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "time", "title": "日期" },
  "yAxis": { "type": "linear" },
  "series": [
    {
      "name": "DAU",
      "data": [
        { "x": "2026-01-01", "y": 12 },
        { "x": "2026-01-08", "y": 18 }
      ]
    }
  ]
}
""")
        @Assert(count(svg, "class=\"symbol\"") == 2)
        @Assert(svg.contains("2026-01"))
    }

    /** smooth 使用二次贝塞尔。 */
    @TestCase
    public func smoothUsesQuadratic(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "趋势", "data": [1, 2, 3], "smooth": true }]
}
""")
        @Assert(svg.contains("Q"))
    }

    /** symbol=none 不画点。 */
    @TestCase
    public func supportsNoSymbol(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "趋势", "data": [1, 2], "symbol": "none" }]
}
""")
        @Assert(!svg.contains("class=\"symbol\""))
    }

    /** 混合数据形状报错。 */
    @TestCase
    public func rejectsMixedShapes(): Unit {
        try {
            draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [1] },
    { "name": "乙", "data": [{ "x": 1, "y": 2 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
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
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "趋势", "data": [1, 2] }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "趋势", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
