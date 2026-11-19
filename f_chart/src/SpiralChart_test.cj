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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class SpiralChart_test {
    private func draw(json: String): String {
        SpiralChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "spiral",
  "title": "月度周期",
  "width": 600,
  "height": 600,
  "turns": 3,
  "startAngle": -90,
  "clockwise": true,
  "series": [
    {
      "name": "周期值",
      "data": [
        { "period": "1月", "value": 12 },
        { "period": "2月", "value": 18 },
        { "period": "3月", "value": 25 },
        { "period": "4月", "value": 20 },
        { "period": "5月", "value": 30 },
        { "period": "6月", "value": 28 }
      ]
    }
  ]
}
"""

    /** 一条螺旋线。 */
    @TestCase
    public func drawsPath(): Unit {
        @Assert(count(draw(sample), "class=\"spiral-path\"") == 1)
    }

    /** 六个数据点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"spiral-point\"") == 6)
    }

    /** 六个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"spiral-label\"") == 6)
        @Assert(svg.contains("1月"))
    }

    /** 首点坐标。 */
    @TestCase
    public func computesFirstPoint(): Unit {
        let point = spiralPoint(0, 4, 1.0, -90.0, true, 100.0)
        @Assert(abs(point[0]) < 1e-9)
        @Assert(abs(point[1] + 25.0) < 1e-9)
    }

    /** 末点坐标。 */
    @TestCase
    public func computesLastPoint(): Unit {
        let point = spiralPoint(3, 4, 1.0, -90.0, true, 100.0)
        @Assert(abs(point[0]) < 1e-9)
        @Assert(abs(point[1] + 100.0) < 1e-9)
    }

    /** 逆时针与顺时针镜像。 */
    @TestCase
    public func flipsDirection(): Unit {
        let cw = spiralPoint(1, 4, 1.0, 0.0, true, 100.0)
        let ccw = spiralPoint(1, 4, 1.0, 0.0, false, 100.0)
        @Assert(abs(cw[1] + ccw[1]) < 1e-9)
        @Assert(abs(cw[0] - ccw[0]) < 1e-9)
    }

    /** 圈数为零。 */
    @TestCase
    public func rejectsZeroTurns(): Unit {
        let json = """
{
  "type": "spiral",
  "turns": 0,
  "series": [
    { "name": "S", "data": [ { "period": "1月", "value": 1 } ] }
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

    /** 负值。 */
    @TestCase
    public func rejectsNegative(): Unit {
        let json = """
{
  "type": "spiral",
  "series": [
    { "name": "S", "data": [ { "period": "1月", "value": -1 } ] }
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
  "type": "radar",
  "series": [
    { "name": "S", "data": [ { "period": "1月", "value": 1 } ] }
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
