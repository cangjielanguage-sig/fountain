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
public class StackedAreaChart_test {
    private func draw(json: String): String {
        StackedAreaChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三层同组：三个面积。 */
    @TestCase
    public func drawsThreeLayers(): Unit {
        let svg = draw("""
{
  "type": "stacked-area",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月"] },
  "series": [
    { "name": "App", "stack": "traffic", "data": [10, 20, 30] },
    { "name": "Web", "stack": "traffic", "data": [20, 10, 15] },
    { "name": "小程序", "stack": "traffic", "data": [30, 10, 5] }
  ]
}
""")
        @Assert(count(svg, "class=\"stacked-area\"") == 3)
        @Assert(count(svg, "class=\"legend-item\"") == 3)
    }

    /** 同组累计：10+20+30=60。 */
    @TestCase
    public func accumulatesSameGroup(): Unit {
        let bounds = stackedAreaBounds(
            ["g", "g", "g"],
            [[10.0, 20.0], [20.0, 10.0], [30.0, 10.0]],
            2
        )
        @Assert(bounds[1] == 60.0)
        @Assert(bounds[0] == 0.0)
    }

    /** 不同分组各自从 0 起算。 */
    @TestCase
    public func separatesGroups(): Unit {
        let bounds = stackedAreaBounds(
            ["a", "b"],
            [[10.0, 10.0], [20.0, 20.0]],
            2
        )
        @Assert(bounds[1] == 20.0)
    }

    /** 负值累计进入下界。 */
    @TestCase
    public func includesNegativeCumulative(): Unit {
        let bounds = stackedAreaBounds(
            ["g", "g"],
            [[20.0, 0.0], [-30.0, 0.0]],
            2
        )
        @Assert(bounds[0] == -10.0)
    }

    /** null 按 0 参与堆叠。 */
    @TestCase
    public func treatsNullAsZero(): Unit {
        let svg = draw("""
{
  "type": "stacked-area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "甲", "data": [10, null, 30] },
    { "name": "乙", "data": [5, 8, 7] }
  ]
}
""")
        @Assert(count(svg, "class=\"stacked-area\"") == 2)
    }

    /** 长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "stacked-area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "甲", "data": [1, 2, 3] },
    { "name": "乙", "data": [1, 2] }
  ]
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
{ "type": "stacked-area" }
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
  "type": "area",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [1] }]
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
        let json = """
{
  "type": "stacked-area",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "甲", "data": [1, 2] },
    { "name": "乙", "data": [2, 1] }
  ]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
