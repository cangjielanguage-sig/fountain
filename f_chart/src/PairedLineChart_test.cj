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
public class PairedLineChart_test {
    private func draw(json: String): String {
        PairedLineChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "paired-line",
  "title": "干预前后指标",
  "xAxis": { "type": "category", "labels": ["干预前", "干预后"] },
  "yAxis": { "type": "linear", "title": "指标值", "min": 0, "max": 100 },
  "series": [
    {
      "name": "受试者",
      "data": [
        { "name": "S1", "before": 62, "after": 78 },
        { "name": "S2", "before": 70, "after": 66 },
        { "name": "S3", "before": 55, "after": 81 },
        { "name": "S4", "before": 80, "after": 85 }
      ]
    }
  ]
}
"""

    /** 四条连线。 */
    @TestCase
    public func drawsLines(): Unit {
        @Assert(count(draw(sample), "class=\"paired-line\"") == 4)
    }

    /** 八个端点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"paired-point\"") == 8)
    }

    /** 四个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"paired-label\"") == 4)
        @Assert(svg.contains("S1"))
    }

    /** 时间点与轴。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("干预前"))
        @Assert(svg.contains("干预后"))
        @Assert(svg.contains("指标值"))
    }

    /** 时间点数量不为二。 */
    @TestCase
    public func rejectsThreeTimePoints(): Unit {
        let json = """
{
  "type": "paired-line",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "S", "data": [ { "name": "S1", "before": 1, "after": 2 } ] }
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

    /** 缺少 after。 */
    @TestCase
    public func rejectsMissingAfter(): Unit {
        let json = """
{
  "type": "paired-line",
  "series": [
    { "name": "S", "data": [ { "name": "S1", "before": 1 } ] }
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

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "slope",
  "series": [
    { "name": "S", "data": [ { "name": "S1", "before": 1, "after": 2 } ] }
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
