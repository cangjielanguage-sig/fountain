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
public class LassoPathChart_test {
    private func draw(json: String): String {
        LassoPathChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "lasso-path",
  "title": "LASSO 系数路径",
  "xAxis": { "type": "linear", "title": "log(lambda)" },
  "yAxis": { "type": "linear", "title": "系数" },
  "variables": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    { "name": "年龄", "data": [{ "x": -4, "y": 0.8 }, { "x": -2, "y": 0.5 }, { "x": 0, "y": 0.1 }, { "x": 2, "y": 0.0 }] },
    { "name": "血压", "data": [{ "x": -4, "y": 0.6 }, { "x": -2, "y": 0.4 }, { "x": 0, "y": 0.2 }, { "x": 2, "y": 0.0 }] },
    { "name": "BMI", "data": [{ "x": -4, "y": 0.3 }, { "x": -2, "y": 0.1 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] },
    { "name": "血糖", "data": [{ "x": -4, "y": 0.2 }, { "x": -2, "y": 0.0 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] }
  ]
}
"""

    /** 四条路径与十六个点。 */
    @TestCase
    public func drawsPaths(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"lasso-line\"") == 4)
        @Assert(count(svg, "class=\"lasso-point\"") == 16)
    }

    /** 图例与轴。 */
    @TestCase
    public func drawsLegend(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("年龄"))
        @Assert(svg.contains("血压"))
        @Assert(svg.contains("log(lambda)"))
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "lasso-path",
  "series": [
    { "name": "年龄", "data": [] }
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
  "type": "learning-curve",
  "series": [
    { "name": "年龄", "data": [ { "x": 1, "y": 0.5 } ] }
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
