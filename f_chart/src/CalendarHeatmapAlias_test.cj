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
public class CalendarHeatmapAlias_test {
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

    /** 90 个日格。 */
    @TestCase
    public func drawsCells(): Unit {
        @Assert(count(draw(sample), "class=\"calendar-cell\"") == 90)
    }

    /** 三个月与七个星期标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"month-label\"") == 3)
        @Assert(count(svg, "class=\"weekday-label\"") == 4)
    }

    /** 最高值使用最后一档颜色。 */
    @TestCase
    public func appliesLastColor(): Unit {
        @Assert(draw(sample).contains("#216e39"))
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "heat-map",
  "series": [ { "name": "提交数", "data": [ { "date": "2026-01-05", "value": 2 } ] } ]
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
