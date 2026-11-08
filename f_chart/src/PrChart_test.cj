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
public class PrChart_test {
    private func draw(json: String): String {
        PrChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "pr",
  "title": "PR 曲线",
  "xAxis": { "type": "linear", "title": "召回率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "精确率", "min": 0, "max": 1 },
  "baseline": 0.12,
  "series": [
    {
      "name": "模型 A（AP=0.72）",
      "ap": 0.72,
      "data": [
        { "x": 0.0, "y": 1.0 }, { "x": 0.2, "y": 0.92 }, { "x": 0.4, "y": 0.81 },
        { "x": 0.6, "y": 0.68 }, { "x": 0.8, "y": 0.45 }, { "x": 1.0, "y": 0.12 }
      ]
    }
  ]
}
"""

    /** 曲线、点与基线。 */
    @TestCase
    public func drawsCurveAndBaseline(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pr-point\"") == 6)
        @Assert(count(svg, "class=\"pr-line\"") == 1)
        @Assert(count(svg, "class=\"pr-baseline\"") == 1)
    }

    /** 未给基线时不输出。 */
    @TestCase
    public func omitsBaseline(): Unit {
        let svg = draw("""
{
  "type": "pr",
  "series": [ { "name": "模型", "data": [ { "x": 0, "y": 1 }, { "x": 1, "y": 0.2 } ] } ]
}
""")
        @Assert(count(svg, "class=\"pr-baseline\"") == 0)
    }

    /** AP 标注。 */
    @TestCase
    public func drawsAp(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pr-ap\"") == 1)
        @Assert(svg.contains("0.72"))
    }

    /** 基线越界。 */
    @TestCase
    public func rejectsBaselineOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "pr",
  "baseline": 1.5,
  "series": [ { "name": "模型", "data": [ { "x": 0, "y": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** AP 越界。 */
    @TestCase
    public func rejectsApOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "pr",
  "series": [ { "name": "模型", "ap": -0.1, "data": [ { "x": 0, "y": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 工作点越界。 */
    @TestCase
    public func rejectsPointOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "pr",
  "series": [ { "name": "模型", "data": [ { "x": 0, "y": 1.5 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        try {
            draw("""
{
  "type": "pr",
  "series": [ { "name": "模型", "data": [] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{ "type": "pr" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "roc",
  "series": [ { "name": "模型", "data": [] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}
