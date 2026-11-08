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
public class ResidualChart_test {
    private func draw(json: String): String {
        ResidualChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "residual",
  "title": "回归残差",
  "xAxis": { "type": "linear", "title": "拟合值" },
  "yAxis": { "type": "linear", "title": "残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "残差",
      "data": [
        { "x": 10, "y": 0.5 }, { "x": 12, "y": -1.2 }, { "x": 14, "y": 0.8 },
        { "x": 16, "y": -0.4 }, { "x": 18, "y": 1.1 }, { "x": 20, "y": -0.9 }
      ]
    }
  ]
}
"""

    /** 六个散点与一条零线。 */
    @TestCase
    public func drawsPointsAndZeroLine(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"residual-point\"") == 6)
        @Assert(count(svg, "class=\"residual-zero\"") == 1)
    }

    /** 全为正残差时 y 范围仍包含 0。 */
    @TestCase
    public func includesZeroWhenAllPositive(): Unit {
        let axis = ChartAxis.parse(None, "linear", true)
        let range = residualYRange(axis, [1.0, 2.0, 3.0])
        @Assert(range[0] < 0.0)
        @Assert(range[1] > 3.0)
    }

    /** 全为负残差时 y 范围仍包含 0。 */
    @TestCase
    public func includesZeroWhenAllNegative(): Unit {
        let axis = ChartAxis.parse(None, "linear", true)
        let range = residualYRange(axis, [-3.0, -2.0, -1.0])
        @Assert(range[0] < -3.0)
        @Assert(range[1] > 0.0)
    }

    /** 显式轴范围被尊重且仍包含 0。 */
    @TestCase
    public func honorsExplicitRange(): Unit {
        let axis = ChartAxis.parse(None, "linear", true)
        axis.min = Some(-5.0)
        axis.max = Some(5.0)
        let range = residualYRange(axis, [1.0, 2.0])
        @Assert(range[0] == -5.0)
        @Assert(range[1] == 5.0)
    }

    /** 非数字 y。 */
    @TestCase
    public func rejectsNonNumericY(): Unit {
        try {
            draw("""
{
  "type": "residual",
  "legend": { "show": false },
  "series": [ { "name": "残差", "data": [ { "x": 1, "y": "a" } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 y 字段。 */
    @TestCase
    public func rejectsMissingY(): Unit {
        try {
            draw("""
{
  "type": "residual",
  "legend": { "show": false },
  "series": [ { "name": "残差", "data": [ { "x": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        try {
            draw("""
{
  "type": "residual",
  "legend": { "show": false },
  "series": [ { "name": "残差", "data": [] } ]
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
{ "type": "residual" }
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
  "series": [ { "name": "残差", "data": [] } ]
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
