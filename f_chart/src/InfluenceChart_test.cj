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
public class InfluenceChart_test {
    private func draw(json: String): String {
        InfluenceChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "influence",
  "title": "杠杆与影响",
  "xAxis": { "type": "linear", "title": "杠杆值" },
  "yAxis": { "type": "linear", "title": "学生化残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
      "data": [
        { "x": 0.05, "y": 0.4, "cooksDistance": 0.02 },
        { "x": 0.08, "y": -1.1, "cooksDistance": 0.04 },
        { "x": 0.12, "y": 0.9, "cooksDistance": 0.06 },
        { "x": 0.20, "y": -2.0, "cooksDistance": 0.18 },
        { "x": 0.25, "y": 1.6, "cooksDistance": 0.12 }
      ]
    }
  ]
}
"""

    /** 五个影响点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"influence-point\"") == 5)
    }

    /** 带标签时输出 influence-label。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw("""
{
  "type": "influence",
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [
      { "x": 0.1, "y": 1.0, "label": "A", "cooksDistance": 0.1 },
      { "x": 0.2, "y": -1.5, "label": "B", "cooksDistance": 0.3 }
    ] }
  ]
}
""")
        @Assert(count(svg, "class=\"influence-label\"") == 2)
        @Assert(svg.contains("A"))
        @Assert(svg.contains("B"))
    }

    /** 零距离半径。 */
    @TestCase
    public func usesBaseRadiusAtZero(): Unit {
        @Assert(abs(influenceRadius(0.0, 0.5) - 4.0) < 1e-9)
    }

    /** 最大距离半径。 */
    @TestCase
    public func usesMaxRadius(): Unit {
        @Assert(abs(influenceRadius(0.5, 0.5) - 12.0) < 1e-9)
    }

    /** 负 Cook 距离。 */
    @TestCase
    public func rejectsNegativeCooksDistance(): Unit {
        try {
            draw("""
{
  "type": "influence",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [ { "x": 0.1, "y": 1.0, "cooksDistance": -1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字杠杆值。 */
    @TestCase
    public func rejectsNonNumericX(): Unit {
        try {
            draw("""
{
  "type": "influence",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [ { "x": "a", "y": 1.0 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        try {
            draw("""
{
  "type": "influence",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [] } ]
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
{ "type": "influence" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "bar",
  "series": [ { "name": "样本", "data": [] } ]
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
