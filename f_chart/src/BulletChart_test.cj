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
public class BulletChart_test {
    private func draw(json: String): String {
        BulletChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "bullet",
  "title": "季度目标完成情况",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "linear", "min": 0, "max": 100, "title": "完成率" },
  "yAxis": { "type": "category", "labels": ["营收", "回款", "新客"] },
  "series": [
    {
      "name": "完成率",
      "data": [
        { "name": "营收", "value": 72, "target": 80, "ranges": [50, 75, 100] },
        { "name": "回款", "value": 88, "target": 85, "ranges": [60, 80, 100] },
        { "name": "新客", "value": 45, "target": 70, "ranges": [40, 70, 100] }
      ]
    }
  ]
}
"""

    /** 九个区间条。 */
    @TestCase
    public func drawsRanges(): Unit {
        @Assert(count(draw(sample), "class=\"bullet-range\"") == 9)
    }

    /** 三个值条。 */
    @TestCase
    public func drawsValues(): Unit {
        @Assert(count(draw(sample), "class=\"bullet-value\"") == 3)
    }

    /** 三条目标线。 */
    @TestCase
    public func drawsTargets(): Unit {
        @Assert(count(draw(sample), "class=\"bullet-target\"") == 3)
    }

    /** 轴标签。 */
    @TestCase
    public func drawsAxis(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("完成率"))
        @Assert(svg.contains("营收"))
        @Assert(svg.contains("100"))
    }

    /** 区间颜色由浅到深。 */
    @TestCase
    public func shadesRanges(): Unit {
        let first = bulletRangeColor(0)
        let last = bulletRangeColor(2)
        @Assert(first.startsWith("#"))
        @Assert(last.startsWith("#"))
        @Assert(first != last)
    }

    /** 区间非递增。 */
    @TestCase
    public func rejectsNonIncreasingRanges(): Unit {
        let json = """
{
  "type": "bullet",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [
      { "name": "A", "value": 10, "target": 20, "ranges": [50, 50, 100] }
    ] }
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

    /** 目标缺失。 */
    @TestCase
    public func rejectsMissingTarget(): Unit {
        let json = """
{
  "type": "bullet",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [
      { "name": "A", "value": 10, "ranges": [50, 75, 100] }
    ] }
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

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        let json = """
{
  "type": "bullet",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [
      { "name": "A", "value": -1, "target": 20, "ranges": [50, 75, 100] }
    ] }
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

    /** 类目数量不匹配。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        let json = """
{
  "type": "bullet",
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "S", "data": [
      { "name": "A", "value": 10, "target": 20, "ranges": [50, 75, 100] }
    ] }
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
  "type": "bar",
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [
      { "name": "A", "value": 10, "target": 20, "ranges": [50, 75, 100] }
    ] }
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
