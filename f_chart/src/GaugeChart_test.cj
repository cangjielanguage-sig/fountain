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
public class GaugeChart_test {
    private func draw(json: String): String {
        GaugeChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "gauge",
  "title": "任务完成率",
  "width": 480,
  "height": 360,
  "min": 0,
  "max": 100,
  "startAngle": -120,
  "endAngle": 120,
  "thresholds": [
    { "value": 60, "color": "#e15759" },
    { "value": 85, "color": "#edc948" },
    { "value": 100, "color": "#59a14f" }
  ],
  "series": [
    { "name": "完成率", "data": [{ "name": "完成率", "value": 72 }] }
  ]
}
"""

    /** 三条色带、一条指针、一个数值。 */
    @TestCase
    public func drawsGauge(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"gauge-band\"") == 3)
        @Assert(count(svg, "class=\"gauge-needle\"") == 1)
        @Assert(count(svg, "class=\"gauge-value\"") == 1)
    }

    /** 中心数值与指标名。 */
    @TestCase
    public func drawsValue(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains(">72<"))
        @Assert(svg.contains("完成率"))
    }

    /** 无阈值时单段色带。 */
    @TestCase
    public func drawsSingleBand(): Unit {
        let json = """
{
  "type": "gauge",
  "series": [ { "name": "完成率", "data": [{ "name": "完成率", "value": 30 }] } ]
}
"""
        @Assert(count(draw(json), "class=\"gauge-band\"") == 1)
    }

    /** 角度线性映射。 */
    @TestCase
    public func mapsAngle(): Unit {
        @Assert(abs(gaugeAngleForValue(0.0, 0.0, 100.0, -120.0, 120.0) + 120.0) < 1e-9)
        @Assert(abs(gaugeAngleForValue(100.0, 0.0, 100.0, -120.0, 120.0) - 120.0) < 1e-9)
        @Assert(abs(gaugeAngleForValue(50.0, 0.0, 100.0, -120.0, 120.0)) < 1e-9)
    }

    /** 数值越界。 */
    @TestCase
    public func rejectsOutOfRange(): Unit {
        let json = sample.replace("\"value\": 72", "\"value\": 120")
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法量程。 */
    @TestCase
    public func rejectsBadRange(): Unit {
        let json = sample.replace("\"max\": 100", "\"max\": 0")
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法角度。 */
    @TestCase
    public func rejectsBadAngle(): Unit {
        let json = sample.replace("\"startAngle\": -120", "\"startAngle\": 150")
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 阈值非递增。 */
    @TestCase
    public func rejectsBadThresholds(): Unit {
        let json = """
{
  "type": "gauge",
  "min": 0,
  "max": 100,
  "thresholds": [
    { "value": 60, "color": "#e15759" },
    { "value": 50, "color": "#edc948" }
  ],
  "series": [ { "name": "完成率", "data": [{ "name": "完成率", "value": 30 }] } ]
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
  "series": [ { "name": "完成率", "data": [{ "name": "完成率", "value": 30 }] } ]
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
