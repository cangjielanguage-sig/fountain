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

@Test
public class DonutChart_test {
    private func draw(json: String): String {
        DonutChart().draw(JsonValue.fromStr(json).asObject())
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

    private let sample: String = """
{
  "type": "donut",
  "innerRadius": 0.55,
  "centerText": "总预算 100%",
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
"""

    /** 四个扇区与一个内孔。 */
    @TestCase
    public func drawsSlicesAndHole(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"donut-slice\"") == 4)
        @Assert(count(svg, "class=\"donut-hole\"") == 1)
    }

    /** 中心文本。 */
    @TestCase
    public func drawsCenterText(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"center-text\"") == 1)
        @Assert(svg.contains("总预算 100%"))
    }

    /** 非法内半径。 */
    @TestCase
    public func rejectsInvalidInnerRadius(): Unit {
        try {
            draw("""
{
  "type": "donut",
  "innerRadius": 1.5,
  "series": [{ "name": "份额", "data": [{ "name": "A", "value": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "donut",
  "series": [{ "name": "份额", "data": [{ "name": "A", "value": -5 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 总和为零。 */
    @TestCase
    public func rejectsZeroTotal(): Unit {
        try {
            draw("""
{
  "type": "donut",
  "series": [{ "name": "份额", "data": [{ "name": "A", "value": 0 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{ "type": "donut" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "donut",
  "series": [
    { "name": "甲", "data": [{ "name": "A", "value": 1 }] },
    { "name": "乙", "data": [{ "name": "B", "value": 2 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "pie",
  "series": [{ "name": "份额", "data": [{ "name": "A", "value": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}
