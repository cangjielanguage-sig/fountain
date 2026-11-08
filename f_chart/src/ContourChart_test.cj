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
public class ContourChart_test {
    private func draw(json: String): String {
        ContourChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "contour",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "levels": 4,
  "series": [
    {
      "name": "响应",
      "data": [
        { "x": 0, "y": 0, "value": 10 }, { "x": 1, "y": 0, "value": 14 }, { "x": 2, "y": 0, "value": 20 },
        { "x": 0, "y": 1, "value": 12 }, { "x": 1, "y": 1, "value": 18 }, { "x": 2, "y": 1, "value": 26 },
        { "x": 0, "y": 2, "value": 16 }, { "x": 1, "y": 2, "value": 24 }, { "x": 2, "y": 2, "value": 34 }
      ]
    }
  ]
}
"""

    /** 3×3 网格四个单元。 */
    @TestCase
    public func drawsCells(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"contour-cell\"") == 4)
    }

    /** 梯度数据产生等值边界。 */
    @TestCase
    public func drawsContourLines(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"contour-line\"") >= 1)
    }

    /** 分层计算。 */
    @TestCase
    public func computesLevels(): Unit {
        @Assert(contourLevel(10.0, 10.0, 34.0, 4) == 0)
        @Assert(contourLevel(34.0, 10.0, 34.0, 4) == 3)
        @Assert(contourLevel(22.0, 10.0, 34.0, 4) == 2)
    }

    /** 非法层级。 */
    @TestCase
    public func rejectsInvalidLevels(): Unit {
        try {
            draw("""
{
  "type": "contour",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "levels": 0,
  "series": [{ "name": "响应", "data": [{ "x": 0, "y": 0, "value": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法插值方式。 */
    @TestCase
    public func rejectsInvalidInterpolate(): Unit {
        try {
            draw("""
{
  "type": "contour",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "interpolate": "cubic",
  "series": [{ "name": "响应", "data": [{ "x": 0, "y": 0, "value": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 网格不完整。 */
    @TestCase
    public func rejectsIncompleteGrid(): Unit {
        try {
            draw("""
{
  "type": "contour",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    {
      "name": "响应",
      "data": [
        { "x": 0, "y": 0, "value": 10 }, { "x": 1, "y": 0, "value": 14 }, { "x": 2, "y": 0, "value": 20 },
        { "x": 0, "y": 1, "value": 12 }, { "x": 1, "y": 1, "value": 18 }, { "x": 2, "y": 1, "value": 26 },
        { "x": 0, "y": 2, "value": 16 }, { "x": 1, "y": 2, "value": 24 }
      ]
    }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值 value。 */
    @TestCase
    public func rejectsNonNumericValue(): Unit {
        try {
            draw("""
{
  "type": "contour",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "响应", "data": [{ "x": 0, "y": 0, "value": "1" }] }]
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
{ "type": "contour" }
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
  "type": "heatmap",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "响应", "data": [{ "x": 0, "y": 0, "value": 1 }] }]
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
