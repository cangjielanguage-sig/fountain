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
public class RadarChart_test {
    private func draw(json: String): String {
        RadarChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 五个指标标签。 */
    @TestCase
    public func drawsIndicators(): Unit {
        let svg = draw("""
{
  "type": "radar",
  "indicators": [
    { "name": "速度", "max": 100 },
    { "name": "力量", "max": 100 },
    { "name": "技巧", "max": 100 },
    { "name": "耐力", "max": 100 },
    { "name": "意识", "max": 100 }
  ],
  "series": [{ "name": "选手", "data": [80, 70, 90, 75, 85] }]
}
""")
        @Assert(count(svg, "class=\"indicator-label\"") == 5)
    }

    /** 两个系列 → 两个多边形、十个顶点。 */
    @TestCase
    public func drawsSeries(): Unit {
        let svg = draw("""
{
  "type": "radar",
  "indicators": [
    { "name": "A", "max": 100 },
    { "name": "B", "max": 100 },
    { "name": "C", "max": 100 },
    { "name": "D", "max": 100 },
    { "name": "E", "max": 100 }
  ],
  "series": [
    { "name": "甲", "data": [10, 20, 30, 40, 50] },
    { "name": "乙", "data": [50, 40, 30, 20, 10] }
  ]
}
""")
        @Assert(count(svg, "class=\"radar-area\"") == 2)
        @Assert(count(svg, "class=\"symbol\"") == 10)
    }

    /** 数据长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "radar",
  "indicators": [
    { "name": "A", "max": 100 },
    { "name": "B", "max": 100 },
    { "name": "C", "max": 100 },
    { "name": "D", "max": 100 },
    { "name": "E", "max": 100 }
  ],
  "series": [{ "name": "甲", "data": [10, 20, 30, 40] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 indicators。 */
    @TestCase
    public func rejectsMissingIndicators(): Unit {
        try {
            draw("""
{
  "type": "radar",
  "series": [{ "name": "甲", "data": [] }]
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
  "type": "pie",
  "indicators": [{ "name": "A", "max": 100 }],
  "series": [{ "name": "甲", "data": [1] }]
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
  "type": "radar",
  "indicators": [{ "name": "A", "max": 100 }, { "name": "B", "max": 100 }, { "name": "C", "max": 100 }],
  "series": [{ "name": "甲", "data": [10, 20, 30] }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "radar",
  "indicators": [{ "name": "A", "max": 100 }, { "name": "B", "max": 100 }, { "name": "C", "max": 100 }],
  "series": [{ "name": "甲", "data": [10, 20, 30] }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
