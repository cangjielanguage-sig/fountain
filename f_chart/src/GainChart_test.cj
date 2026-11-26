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
public class GainChart_test {
    private func draw(json: String): String {
        GainChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "gain",
  "title": "累积增益",
  "xAxis": { "type": "linear", "title": "样本比例", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "捕获比例", "min": 0, "max": 1 },
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.1, "y": 0.42 }, { "x": 0.2, "y": 0.62 }, { "x": 0.4, "y": 0.82 },
        { "x": 0.6, "y": 0.91 }, { "x": 0.8, "y": 0.97 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
"""

    /** 一条曲线与六个点。 */
    @TestCase
    public func drawsCurve(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"gain-line\"") == 1)
        @Assert(count(svg, "class=\"gain-point\"") == 6)
    }

    /** 一条对角线。 */
    @TestCase
    public func drawsBaseline(): Unit {
        @Assert(count(draw(sample), "class=\"gain-baseline\"") == 1)
    }

    /** 轴标题。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("样本比例"))
        @Assert(svg.contains("捕获比例"))
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "gain",
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
  "type": "lift",
  "series": [
    { "name": "S", "data": [ { "x": 0.5, "y": 0.8 } ] }
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
