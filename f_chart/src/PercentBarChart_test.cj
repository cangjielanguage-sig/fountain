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
public class PercentBarChart_test {
    private func draw(json: String): String {
        PercentBarChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "percent-bar",
  "title": "各季度收入构成",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "series": [
    { "name": "产品 A", "data": [30, 40, 35, 50] },
    { "name": "产品 B", "data": [50, 40, 45, 30] },
    { "name": "产品 C", "data": [20, 20, 20, 20] }
  ]
}
"""

    /** 十二根柱。 */
    @TestCase
    public func drawsBars(): Unit {
        @Assert(count(draw(sample), "class=\"bar\"") == 12)
    }

    /** 三个图例。 */
    @TestCase
    public func drawsLegend(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("产品 A"))
        @Assert(svg.contains("产品 B"))
        @Assert(svg.contains("产品 C"))
    }

    /** 类目标签。 */
    @TestCase
    public func drawsCategories(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("Q1"))
        @Assert(svg.contains("Q4"))
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 数据长度不一致。 */
    @TestCase
    public func rejectsMisalignedSeries(): Unit {
        let json = """
{
  "type": "percent-bar",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "series": [
    { "name": "S", "data": [1, 2, 3] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }
}
