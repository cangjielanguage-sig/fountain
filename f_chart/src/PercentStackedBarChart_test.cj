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
public class PercentStackedBarChart_test {
    private func draw(json: String): String {
        PercentStackedBarChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 2 系列 × 2 类目 = 4 段。 */
    @TestCase
    public func drawsFourSegments(): Unit {
        let svg = draw("""
{
  "type": "percent-stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [60, 50] },
    { "name": "乙", "data": [40, 50] }
  ]
}
""")
        @Assert(count(svg, "class=\"bar\"") == 4)
    }

    /** 归一化后两段合计 100%。 */
    @TestCase
    public func normalizesToHundred(): Unit {
        @Assert(percentStackedValue(60.0, 100.0) == 60.0)
        @Assert(percentStackedValue(40.0, 100.0) == 40.0)
        @Assert(percentStackedValue(-30.0, 100.0) == 30.0)
    }

    /** 默认 y 轴为 0–100。 */
    @TestCase
    public func usesHundredPercentAxis(): Unit {
        let svg = draw("""
{
  "type": "percent-stacked-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "linear", "labelFormat": "{value}%" },
  "series": [
    { "name": "甲", "data": [60] },
    { "name": "乙", "data": [40] }
  ]
}
""")
        @Assert(svg.contains("100%"))
    }

    /** 同类目的段共用 x。 */
    @TestCase
    public func segmentsShareX(): Unit {
        let band = BandScale(0.0, 200.0, 2)
        @Assert(stackedBarX(band, 0, 20.0) == stackedBarX(band, 0, 20.0))
    }

    /** 全零类目跳过。 */
    @TestCase
    public func skipsZeroCategories(): Unit {
        let svg = draw("""
{
  "type": "percent-stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [0, 30] },
    { "name": "乙", "data": [0, 70] }
  ]
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
  "type": "stacked-bar",
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
  "type": "percent-stacked-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [1, 2] },
    { "name": "乙", "data": [2, 1] }
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
  "type": "percent-stacked-bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [1] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
