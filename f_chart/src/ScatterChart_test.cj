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
public class ScatterChart_test {
    private func draw(json: String): String {
        ScatterChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三个点。 */
    @TestCase
    public func drawsThreePoints(): Unit {
        let svg = draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear", "title": "身高" },
  "yAxis": { "type": "linear", "title": "体重" },
  "series": [
    { "name": "样本", "data": [{ "x": 160, "y": 52 }, { "x": 170, "y": 62 }, { "x": 180, "y": 75 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"symbol\"") == 3)
    }

    /** 双数值轴刻度。 */
    @TestCase
    public func drawsNumericAxes(): Unit {
        let svg = draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "样本", "data": [{ "x": 0, "y": 0 }, { "x": 100, "y": 100 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"tick-label\"") >= 2)
    }

    /** 多系列颜色来自调色板。 */
    @TestCase
    public func usesPalettePerSeries(): Unit {
        let svg = draw("""
{
  "type": "scatter",
  "theme": { "palette": ["#101010", "#202020"] },
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "data": [{ "x": 1, "y": 1 }] },
    { "name": "乙", "data": [{ "x": 2, "y": 2 }] }
  ]
}
""")
        @Assert(svg.contains("fill=\"#101010\""))
        @Assert(svg.contains("fill=\"#202020\""))
    }

    /** 时间轴。 */
    @TestCase
    public func supportsTimeAxis(): Unit {
        let svg = draw("""
{
  "type": "scatter",
  "xAxis": { "type": "time" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "样本", "data": [{ "x": "2026-01-01", "y": 1 }, { "x": "2026-01-10", "y": 5 }] }
  ]
}
""")
        @Assert(svg.contains("2026-01"))
    }

    /** 非数值 x 报错。 */
    @TestCase
    public func rejectsNonNumericX(): Unit {
        try {
            draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": "bad", "y": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
            @Assert(error.path == "series[0].data[0].x")
        }
    }

    /** 缺 y 报错。 */
    @TestCase
    public func rejectsMissingY(): Unit {
        try {
            draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "line",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "data": [] }]
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
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": 1, "y": 2 }] }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": 1, "y": 2 }] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
