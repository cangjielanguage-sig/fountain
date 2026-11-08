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
public class BarChart_test {
    private func draw(json: String): String {
        BarChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三个类目生成三根柱。 */
    @TestCase
    public func drawsThreeBars(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "title": "月度销售额",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [{ "name": "销售额", "data": [120, 200, 150] }]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 3)
    }

    /** 缺省画布为 800×480。 */
    @TestCase
    public func usesDefaultCanvasSize(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [10] }]
}
""")
        @Assert(svg.contains("viewBox=\"0 0 800 480\""))
    }

    /** 显式宽高写入 viewBox。 */
    @TestCase
    public func usesExplicitCanvasSize(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "width": 640,
  "height": 360,
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [10] }]
}
""")
        @Assert(svg.contains("viewBox=\"0 0 640 360\""))
    }

    /** 类目标签出现在输出中。 */
    @TestCase
    public func drawsCategoryLabels(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["一月", "二月", "三月"] },
  "series": [{ "data": [1, 2, 3] }]
}
""")
        @Assert(svg.contains("一月"))
        @Assert(svg.contains("二月"))
        @Assert(svg.contains("三月"))
    }

    /** 未指定颜色时使用主题调色板首色。 */
    @TestCase
    public func usesPaletteColor(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "theme": { "palette": ["#112233", "#445566"] },
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "data": [1, 2] }]
}
""")
        @Assert(svg.contains("fill=\"#112233\""))
    }

    /** series.color 优先于调色板。 */
    @TestCase
    public func seriesColorOverridesPalette(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "theme": { "palette": ["#112233"] },
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1], "color": "#abcdef" }]
}
""")
        @Assert(svg.contains("fill=\"#abcdef\""))
        @Assert(!svg.contains("fill=\"#112233\""))
    }

    /** 默认画 5 条左右的水平网格线。 */
    @TestCase
    public func drawsGridLines(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "linear", "grid": true },
  "series": [{ "data": [10, 20, 30] }]
}
""")
        @Assert(count(svg, "class=\"grid\"") >= 2)
    }

    /** 标题进入输出。 */
    @TestCase
    public func drawsTitle(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "title": "季度销售",
  "xAxis": { "type": "category", "labels": ["Q1"] },
  "series": [{ "data": [10] }]
}
""")
        @Assert(svg.contains("季度销售"))
    }

    /** type 不匹配时抛 UnsupportedChart。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 缺少 series 时抛 MissingField。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] }
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
            @Assert(error.path == "series")
        }
    }

    /** 非数值数据抛 InvalidValue，并带元素路径。 */
    @TestCase
    public func rejectsNonNumericValue(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "data": [1, "bad"] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
            @Assert(error.path == "series[0].data[1]")
        }
    }

    /** 标签与数据长度不一致抛 InvalidValue。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "data": [1, 2, 3] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
            @Assert(error.path == "series[0].data")
        }
    }

    /** 负值柱带 bar-negative 标记。 */
    @TestCase
    public func marksNegativeBars(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["降", "升"] },
  "series": [{ "data": [-10, 20] }]
}
""")
        @Assert(count(svg, "class=\"bar bar-negative\"") == 1)
    }

    /** null 数据点跳过。 */
    @TestCase
    public func skipsNullValues(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "data": [10, null, 30] }]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 2)
    }

    /** 同一输入输出逐字节一致。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "data": [1.25, 2.5] }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 输出可被 f_svg 解析。 */
    @TestCase
    public func outputIsParseableSvg(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1] }]
}
""")
        let document = SvgParser.parse(svg)
        @Assert(document.root.tag == "svg")
    }

    /** 单系列且无名称时自动隐藏图例。 */
    @TestCase
    public func hidesLegendForUnnamedSingleSeries(): Unit {
        let svg = draw("""
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "data": [1] }]
}
""")
        @Assert(!svg.contains("legend-item"))
    }
}
