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
public class CalendarHeatmapChart_test {
    private func draw(json: String): String {
        CalendarHeatmapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "calendar-heatmap",
  "title": "提交活跃度",
  "width": 900,
  "height": 220,
  "startDate": "2026-01-01",
  "endDate": "2026-03-31",
  "cellSize": 14,
  "weekStart": "mon",
  "colorRange": ["#ebedf0", "#9be9a8", "#40c463", "#216e39"],
  "series": [
    {
      "name": "提交数",
      "data": [
        { "date": "2026-01-05", "value": 2 },
        { "date": "2026-01-06", "value": 5 },
        { "date": "2026-01-12", "value": 8 },
        { "date": "2026-02-03", "value": 3 },
        { "date": "2026-02-04", "value": 12 },
        { "date": "2026-03-09", "value": 6 }
      ]
    }
  ]
}
"""

    /** 一季度共 90 个单元格。 */
    @TestCase
    public func drawsQuarter(): Unit {
        @Assert(count(draw(sample), "class=\"calendar-cell\"") == 90)
    }

    /** 未给范围时按数据最小/最大日期。 */
    @TestCase
    public func usesDefaultRange(): Unit {
        let svg = draw("""
{
  "type": "calendar-heatmap",
  "series": [ { "name": "值", "data": [
    { "date": "2026-01-05", "value": 1 },
    { "date": "2026-01-12", "value": 2 }
  ] } ]
}
""")
        @Assert(count(svg, "class=\"calendar-cell\"") == 8)
    }

    /** 星期一开头的星期四下标为 3。 */
    @TestCase
    public func computesMondayWeekday(): Unit {
        let days = ChartTime.parseDays("2026-01-01", "date")
        @Assert(calendarWeekday(days, "mon") == 3)
    }

    /** 星期日开头的星期四下标为 4。 */
    @TestCase
    public func computesSundayWeekday(): Unit {
        let days = ChartTime.parseDays("2026-01-01", "date")
        @Assert(calendarWeekday(days, "sun") == 4)
    }

    /** 颜色分档端点与中点。 */
    @TestCase
    public func bucketsColors(): Unit {
        let colors = ["#ebedf0", "#9be9a8", "#40c463", "#216e39"]
        @Assert(calendarColor(0.0, colors) == colors[0])
        @Assert(calendarColor(0.5, colors) == colors[2])
        @Assert(calendarColor(1.0, colors) == colors[3])
    }

    /** 范围倒置。 */
    @TestCase
    public func rejectsInvertedRange(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "startDate": "2026-02-01",
  "endDate": "2026-01-01",
  "series": [ { "name": "值", "data": [ { "date": "2026-01-15", "value": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 显式范围外的数据。 */
    @TestCase
    public func rejectsOutOfRangeDate(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "startDate": "2026-01-01",
  "endDate": "2026-01-31",
  "series": [ { "name": "值", "data": [ { "date": "2026-02-01", "value": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "series": [ { "name": "值", "data": [ { "date": "2026-01-05", "value": -1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 weekStart。 */
    @TestCase
    public func rejectsInvalidWeekStart(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "weekStart": "tue",
  "series": [ { "name": "值", "data": [ { "date": "2026-01-05", "value": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 颜色不足两个。 */
    @TestCase
    public func rejectsTooFewColors(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "colorRange": ["#ffffff"],
  "series": [ { "name": "值", "data": [ { "date": "2026-01-05", "value": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** cellSize 必须大于 0。 */
    @TestCase
    public func rejectsNonPositiveCellSize(): Unit {
        try {
            draw("""
{
  "type": "calendar-heatmap",
  "cellSize": 0,
  "series": [ { "name": "值", "data": [ { "date": "2026-01-05", "value": 1 } ] } ]
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
  "type": "calendar-heatmap",
  "series": [ { "name": "值", "data": [] } ]
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
{ "type": "calendar-heatmap" }
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
  "type": "heatmap",
  "series": [ { "name": "值", "data": [] } ]
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
