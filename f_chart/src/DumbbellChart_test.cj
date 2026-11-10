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
public class DumbbellChart_test {
    private func draw(json: String): String {
        DumbbellChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "dumbbell",
  "title": "两年得分变化",
  "xAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["A 团队", "B 团队", "C 团队"] },
  "series": [
    {
      "name": "2025 → 2026",
      "data": [
        { "name": "A 团队", "low": 60, "high": 82 },
        { "name": "B 团队", "low": 75, "high": 68 },
        { "name": "C 团队", "low": 52, "high": 74 }
      ]
    }
  ]
}
"""

    /** 三条连线。 */
    @TestCase
    public func drawsLines(): Unit {
        @Assert(count(draw(sample), "class=\"dumbbell-line\"") == 3)
    }

    /** 六个端点。 */
    @TestCase
    public func drawsEndpoints(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"dumbbell-low\"") == 3)
        @Assert(count(svg, "class=\"dumbbell-high\"") == 3)
    }

    /** 轴与类目。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("得分"))
        @Assert(svg.contains("A 团队"))
        @Assert(svg.contains("100"))
    }

    /** 缺省范围。 */
    @TestCase
    public func computesDefaultRange(): Unit {
        let json = """
{
  "type": "dumbbell",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [ { "name": "A", "low": 20, "high": 40 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"dumbbell-line\"") == 1)
    }

    /** 缺少 high。 */
    @TestCase
    public func rejectsMissingHigh(): Unit {
        let json = """
{
  "type": "dumbbell",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [ { "name": "A", "low": 20 } ] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类目数量不匹配。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        let json = """
{
  "type": "dumbbell",
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "S", "data": [ { "name": "A", "low": 20, "high": 30 } ] }
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

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "bullet",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [ { "name": "A", "low": 20, "high": 30 } ] }
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
}
