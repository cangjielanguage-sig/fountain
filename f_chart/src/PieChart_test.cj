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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class PieChart_test {
    private func draw(json: String): String {
        PieChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "pie",
  "startAngle": 0,
  "showPercent": true,
  "series": [
    {
      "name": "份额",
      "data": [
        { "name": "品牌 A", "value": 38 },
        { "name": "品牌 B", "value": 27 },
        { "name": "品牌 C", "value": 20 },
        { "name": "其他", "value": 15 }
      ]
    }
  ]
}
"""

    /** 四个扇区。 */
    @TestCase
    public func drawsSlices(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pie-slice\"") == 4)
    }

    /** 百分比标签。 */
    @TestCase
    public func drawsPercentLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pie-label\"") == 4)
        @Assert(svg.contains("38.0%"))
    }

    /** 占比计算。 */
    @TestCase
    public func computesFractions(): Unit {
        let fractions = pieFractions([38.0, 27.0, 20.0, 15.0])
        @Assert(fractions.size == 4)
        @Assert(abs(fractions[0] - 0.38) < 1e-9)
        @Assert(abs(fractions[1] - 0.27) < 1e-9)
        @Assert(abs(fractions[2] - 0.20) < 1e-9)
        @Assert(abs(fractions[3] - 0.15) < 1e-9)
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "pie",
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
  "type": "pie",
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
{ "type": "pie" }
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
  "type": "pie",
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
  "type": "donut",
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
