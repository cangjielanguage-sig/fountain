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
public class AreaChart_test {
    private func draw(json: String): String {
        AreaChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 四个类目：一条面积 + 一条折线。 */
    @TestCase
    public func drawsFilledArea(): Unit {
        let svg = draw("""
{
  "type": "area",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [{ "name": "注册用户", "data": [20, 45, 75, 110] }]
}
""")
        @Assert(count(svg, "class=\"area\"") == 1)
        @Assert(count(svg, "class=\"line\"") == 1)
    }

    /** 面积透明度来自 areaStyle.opacity。 */
    @TestCase
    public func respectsOpacity(): Unit {
        let svg = draw("""
{
  "type": "area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "值", "data": [1, 2, 3], "areaStyle": { "opacity": 0.25 } }]
}
""")
        @Assert(svg.contains("fill-opacity=\"0.25\""))
    }

    /** 中间缺测断成两段。 */
    @TestCase
    public func breaksOnNull(): Unit {
        let svg = draw("""
{
  "type": "area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D", "E"] },
  "series": [{ "name": "值", "data": [10, 20, null, 40, 50] }]
}
""")
        @Assert(count(svg, "class=\"area\"") == 2)
        @Assert(count(svg, "class=\"line\"") == 2)
    }

    /** 连续点数据。 */
    @TestCase
    public func supportsContinuousPoints(): Unit {
        let svg = draw("""
{
  "type": "area",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "值", "data": [{ "x": 0, "y": 5 }, { "x": 10, "y": 15 }] }]
}
""")
        @Assert(count(svg, "class=\"area\"") == 1)
        @Assert(count(svg, "class=\"tick-label\"") >= 2)
    }

    /** 平滑面积使用二次贝塞尔。 */
    @TestCase
    public func smoothUsesQuadratic(): Unit {
        let svg = draw("""
{
  "type": "area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "值", "data": [1, 3, 2], "smooth": true }]
}
""")
        @Assert(svg.contains(" Q "))
    }

    /** 混用数据形状。 */
    @TestCase
    public func rejectsMixedShapes(): Unit {
        try {
            draw("""
{
  "type": "area",
  "xAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "data": [1, 2, 3] },
    { "name": "乙", "data": [{ "x": 0, "y": 1 }, { "x": 1, "y": 2 }] }
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
{ "type": "area" }
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
  "type": "line",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "值", "data": [1] }]
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
  "type": "area",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "值", "data": [3, 1, 2] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
