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
public class BlandAltmanChart_test {
    private func draw(json: String): String {
        BlandAltmanChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "bland-altman",
  "title": "两种测量方法一致性",
  "xAxis": { "type": "linear", "title": "均值" },
  "yAxis": { "type": "linear", "title": "差值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量对",
      "data": [
        { "x": 10.2, "y": 10.5 }, { "x": 12.0, "y": 11.6 }, { "x": 14.5, "y": 14.9 },
        { "x": 16.1, "y": 15.8 }, { "x": 18.3, "y": 18.9 }, { "x": 20.0, "y": 19.5 }
      ]
    }
  ]
}
"""

    /** 六个散点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"bland-altman-point\"") == 6)
    }

    /** 三条参考线。 */
    @TestCase
    public func drawsLimits(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"bland-altman-mean\"") == 1)
        @Assert(count(svg, "class=\"bland-altman-limit\"") == 2)
    }

    /** 轴标题。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("均值"))
        @Assert(svg.contains("差值"))
    }

    /** 恒定差值。 */
    @TestCase
    public func constantDiff(): Unit {
        let stats = blandAltmanStats([[0.0, 1.0], [0.0, 1.0], [0.0, 1.0]])
        @Assert(stats.size == 3)
        @Assert(abs(stats[0] - 1.0) < 1e-9)
        @Assert(abs(stats[1] - 1.0) < 1e-9)
        @Assert(abs(stats[2] - 1.0) < 1e-9)
    }

    /** 单对测量。 */
    @TestCase
    public func singlePair(): Unit {
        let stats = blandAltmanStats([[5.0, 7.0]])
        @Assert(abs(stats[0] - 2.0) < 1e-9)
        @Assert(abs(stats[1] - 2.0) < 1e-9)
        @Assert(abs(stats[2] - 2.0) < 1e-9)
    }

    /** 标准差界限。 */
    @TestCase
    public func computesSdLimits(): Unit {
        let stats = blandAltmanStats([[0.0, 0.0], [0.0, 2.0]])
        @Assert(abs(stats[0] - 1.0) < 1e-9)
        let sd = sqrt(2.0)
        @Assert(abs(stats[1] - (1.0 - 1.96 * sd)) < 1e-9)
        @Assert(abs(stats[2] - (1.0 + 1.96 * sd)) < 1e-9)
    }

    /** 缺少 y。 */
    @TestCase
    public func rejectsMissingY(): Unit {
        let json = """
{
  "type": "bland-altman",
  "series": [
    { "name": "S", "data": [ { "x": 1.0 } ] }
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
  "type": "scatter",
  "series": [
    { "name": "S", "data": [ { "x": 1.0, "y": 2.0 } ] }
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
