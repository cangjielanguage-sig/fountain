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
package fountain::f_chart.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_chart.*
import fountain::f_data.json.*

@Test
public class TuiLineChart_test {
    private func draw(json: String): String {
        TuiLineChart().draw(JsonValue.fromStr(json).asObject())
    }

    private func count(text: String, needle: String): Int64 {
        var total = 0
        var from = 0
        while (let Some(index) <- text.indexOf(needle, from)) {
            total++
            from = index + needle.toArray().size
        }
        total
    }

    private let categorySample: String = """
{
  "type": "line",
  "title": "周活跃用户",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "活跃", "data": [120, 160, 140, 200, 180] }
  ]
}
"""

    /** 折线与数据点。 */
    @TestCase
    public func drawsLineAndPoints(): Unit {
        let svg = draw(categorySample)
        let plain = tuiStripAnsi(svg)
        @Assert(plain.contains("*"))
        @Assert(plain.contains("o"))
        @Assert(plain.contains("周活跃用户"))
        @Assert(plain.contains("周一"))
        @Assert(plain.contains("周五"))
    }

    /** null 断开折线但保留两侧点。 */
    @TestCase
    public func breaksOnNull(): Unit {
        let json = """
{
  "type": "line",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [ { "name": "S", "data": [1, null, 3] } ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(count(plain, "o") >= 2)
    }

    /** 数值 XY 轴。 */
    @TestCase
    public func supportsNumericAxis(): Unit {
        let json = """
{
  "type": "line",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "linear", "title": "时间" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "S", "data": [ { "x": 0, "y": 10 }, { "x": 5, "y": 30 }, { "x": 10, "y": 20 } ] }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("*"))
        @Assert(plain.contains("时间"))
    }

    /** 时间轴标签为日期。 */
    @TestCase
    public func supportsTimeAxis(): Unit {
        let json = """
{
  "type": "line",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "time" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "S", "data": [
      { "x": "2026-01-01", "y": 10 },
      { "x": "2026-02-01", "y": 30 },
      { "x": "2026-03-01", "y": 20 }
    ] }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("2026-"))
        @Assert(plain.contains("*"))
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "scatter", "series": [ { "name": "S", "data": [1, 2] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
