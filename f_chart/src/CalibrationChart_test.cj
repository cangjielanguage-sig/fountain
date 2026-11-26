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
public class CalibrationChart_test {
    private func draw(json: String): String {
        CalibrationChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "calibration",
  "title": "概率校准",
  "xAxis": { "type": "linear", "title": "预测概率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "实际频率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.05, "y": 0.08 }, { "x": 0.15, "y": 0.12 }, { "x": 0.30, "y": 0.35 },
        { "x": 0.50, "y": 0.46 }, { "x": 0.70, "y": 0.74 }, { "x": 0.90, "y": 0.88 }
      ]
    }
  ]
}
"""

    /** 一条曲线与六个点。 */
    @TestCase
    public func drawsCurve(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"calibration-line\"") == 1)
        @Assert(count(svg, "class=\"calibration-point\"") == 6)
    }

    /** 默认显示对角线。 */
    @TestCase
    public func drawsDiagonal(): Unit {
        @Assert(count(draw(sample), "class=\"calibration-diagonal\"") == 1)
    }

    /** 关闭对角线。 */
    @TestCase
    public func hidesDiagonal(): Unit {
        let json = """
{
  "type": "calibration",
  "diagonal": false,
  "series": [
    { "name": "S", "data": [ { "x": 0.2, "y": 0.3 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"calibration-diagonal\"") == 0)
    }

    /** 轴标题。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("预测概率"))
        @Assert(svg.contains("实际频率"))
    }

    /** 非法分箱数。 */
    @TestCase
    public func rejectsBinCount(): Unit {
        let json = """
{
  "type": "calibration",
  "binCount": 0,
  "series": [
    { "name": "S", "data": [ { "x": 0.2, "y": 0.3 } ] }
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

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "calibration",
  "series": [
    { "name": "S", "data": [] }
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
  "type": "gain",
  "series": [
    { "name": "S", "data": [ { "x": 0.2, "y": 0.3 } ] }
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
