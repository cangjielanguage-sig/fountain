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
public class TuiScatterChart_test {
    private func draw(json: String): String {
        TuiScatterChart().draw(JsonValue.fromStr(json).asObject())
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

    private let sample: String = """
{
  "type": "scatter",
  "title": "身高体重",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "linear", "title": "身高" },
  "yAxis": { "type": "linear", "title": "体重" },
  "series": [
    { "name": "样本", "data": [
      { "x": 160, "y": 55 }, { "x": 165, "y": 60 }, { "x": 170, "y": 65 },
      { "x": 175, "y": 70 }, { "x": 180, "y": 75 }
    ] }
  ]
}
"""

    /** 散点标记与标题。 */
    @TestCase
    public func drawsPoints(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("o"))
        @Assert(plain.contains("身高体重"))
        @Assert(count(plain, "o") >= 4)
    }

    /** 轴标题与刻度。 */
    @TestCase
    public func drawsAxes(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("身高"))
        @Assert(plain.contains("体重"))
        @Assert(plain.contains("└"))
    }

    /** 负 y 值。 */
    @TestCase
    public func handlesNegativeY(): Unit {
        let json = """
{
  "type": "scatter",
  "width": 50,
  "height": 16,
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [ { "name": "S", "data": [ { "x": 1, "y": -5 }, { "x": 2, "y": 5 } ] } ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("o"))
        @Assert(plain.contains("-5") || plain.contains("0"))
    }

    /** 时间横轴。 */
    @TestCase
    public func supportsTimeAxis(): Unit {
        let json = """
{
  "type": "scatter",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "time" },
  "yAxis": { "type": "linear" },
  "series": [ { "name": "S", "data": [
    { "x": "2026-01-01", "y": 10 },
    { "x": "2026-02-01", "y": 20 }
  ] } ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("2026-"))
        @Assert(plain.contains("o"))
    }

    /** 类型错误。 */
    @TestCase
    public func rejectsType(): Unit {
        try {
            draw("""
{ "type": "line", "series": [ { "name": "S", "data": [1] } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
