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
public class Histogram2DChart_test {
    private func draw(json: String): String {
        Histogram2DChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 方形单元数量。 */
    @TestCase
    public func drawsSquareCells(): Unit {
        let svg = draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    {
      "name": "样本",
      "bins": [4, 4],
      "shape": "square",
      "data": [{ "x": 1, "y": 1 }, { "x": 5, "y": 5 }, { "x": 9, "y": 9 }]
    }
  ]
}
""")
        @Assert(count(svg, "class=\"cell\"") == 3)
    }

    /** 默认六边形。 */
    @TestCase
    public func drawsHexagonsByDefault(): Unit {
        let svg = draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "样本", "bins": [4, 4], "data": [{ "x": 1, "y": 1 }, { "x": 9, "y": 9 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"hexagon\"") == 2)
    }

    /** 分箱计数。 */
    @TestCase
    public func computesCounts(): Unit {
        let result = histogram2DCounts(
            [Point2D(1.0, 1.0), Point2D(1.0, 1.0), Point2D(9.0, 9.0)],
            2,
            2
        )
        @Assert(result.counts.size == 4)
        @Assert(result.counts[0] == 2)
        @Assert(result.counts[1] == 0)
        @Assert(result.counts[2] == 0)
        @Assert(result.counts[3] == 1)
    }

    /** 非法 bins。 */
    @TestCase
    public func rejectsInvalidBins(): Unit {
        try {
            draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "bins": [0, 4], "data": [{ "x": 1, "y": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 shape。 */
    @TestCase
    public func rejectsInvalidShape(): Unit {
        try {
            draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "shape": "triangle", "data": [{ "x": 1, "y": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值坐标。 */
    @TestCase
    public func rejectsNonNumericPoint(): Unit {
        try {
            draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": "1", "y": 2 }] }]
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
{ "type": "2d-histogram" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "data": [{ "x": 1, "y": 1 }] },
    { "name": "乙", "data": [{ "x": 2, "y": 2 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [{ "x": 1, "y": 1 }] }]
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
        let json = """
{
  "type": "2d-histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "bins": [4, 4], "data": [{ "x": 1, "y": 1 }, { "x": 5, "y": 5 }] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
