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
public class SlopeChart_test {
    private func draw(json: String): String {
        SlopeChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "slope",
  "title": "排名变化",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "series": [
    { "name": "A 团队", "data": [60, 82] },
    { "name": "B 团队", "data": [75, 68] },
    { "name": "C 团队", "data": [52, 74] }
  ]
}
"""

    /** 三条斜率线。 */
    @TestCase
    public func drawsLines(): Unit {
        @Assert(count(draw(sample), "class=\"slope-line\"") == 3)
    }

    /** 六个端点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"slope-point\"") == 6)
    }

    /** 三个右侧标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"slope-label\"") == 3)
        @Assert(svg.contains("A 团队"))
    }

    /** 两个时间点。 */
    @TestCase
    public func drawsTimePoints(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("2025"))
        @Assert(svg.contains("2026"))
    }

    /** 时间点数量不为二。 */
    @TestCase
    public func rejectsThreeTimePoints(): Unit {
        let json = """
{
  "type": "slope",
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "series": [
    { "name": "A", "data": [1, 2] }
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

    /** 数据长度不为二。 */
    @TestCase
    public func rejectsDataLength(): Unit {
        let json = """
{
  "type": "slope",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "series": [
    { "name": "A", "data": [1, 2, 3] }
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

    /** 空系列。 */
    @TestCase
    public func rejectsEmptySeries(): Unit {
        let json = """
{
  "type": "slope",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "series": []
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "line",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "series": [
    { "name": "A", "data": [1, 2] }
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
