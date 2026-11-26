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
public class PdpChart_test {
    private func draw(json: String): String {
        PdpChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "pdp",
  "title": "年龄对预测的影响",
  "xAxis": { "type": "linear", "title": "年龄" },
  "yAxis": { "type": "linear", "title": "预测值" },
  "feature": "年龄",
  "legend": { "show": false },
  "series": [
    {
      "name": "PDP",
      "data": [
        { "x": 20, "y": 0.12 }, { "x": 30, "y": 0.28 }, { "x": 40, "y": 0.45 },
        { "x": 50, "y": 0.58 }, { "x": 60, "y": 0.62 }, { "x": 70, "y": 0.55 }
      ]
    }
  ]
}
"""

    /** 一条曲线与六个点。 */
    @TestCase
    public func drawsCurve(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pdp-line\"") == 1)
        @Assert(count(svg, "class=\"pdp-point\"") == 6)
    }

    /** 特征标注。 */
    @TestCase
    public func drawsFeature(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pdp-feature\"") == 1)
        @Assert(svg.contains("年龄"))
    }

    /** 轴标题。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("预测值"))
        @Assert(svg.contains("年龄"))
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "pdp",
  "series": [
    { "name": "PDP", "data": [] }
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
  "type": "shap",
  "series": [
    { "name": "PDP", "data": [ { "x": 1, "y": 0.5 } ] }
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
