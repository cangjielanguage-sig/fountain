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
public class ScatterMatrixChart_test {
    private func draw(json: String): String {
        ScatterMatrixChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "scatter-matrix",
  "variables": ["身高", "体重", "年龄"],
  "series": [
    {
      "name": "样本",
      "data": [
        [160, 52, 22], [165, 56, 25], [168, 60, 28],
        [170, 62, 31], [172, 65, 35], [175, 68, 38],
        [178, 72, 42], [180, 75, 45], [183, 80, 50]
      ]
    }
  ]
}
"""

    /** 三变量：3 个对角标签 + 6 个非对角单元 × 9 点。 */
    @TestCase
    public func drawsPointsAndLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"diag-label\"") == 3)
        @Assert(count(svg, "class=\"matrix-point\"") == 54)
    }

    /** 列范围。 */
    @TestCase
    public func computesColumnRange(): Unit {
        let rows = [[160.0, 52.0], [183.0, 80.0], [170.0, 60.0]]
        let range = columnRange(rows, 0)
        @Assert(range[0] == 160.0)
        @Assert(range[1] == 183.0)
        let second = columnRange(rows, 1)
        @Assert(second[0] == 52.0)
        @Assert(second[1] == 80.0)
    }

    /** 行长度不匹配。 */
    @TestCase
    public func rejectsRowLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "scatter-matrix",
  "variables": ["A", "B", "C"],
  "series": [{ "name": "样本", "data": [[1, 2]] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空变量。 */
    @TestCase
    public func rejectsEmptyVariables(): Unit {
        try {
            draw("""
{
  "type": "scatter-matrix",
  "variables": [],
  "series": [{ "name": "样本", "data": [] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "scatter-matrix",
  "variables": ["A", "B"],
  "series": [{ "name": "样本", "data": [[1, "2"]] }]
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
{
  "type": "scatter-matrix",
  "variables": ["A", "B"]
}
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
  "type": "parallel-coordinates",
  "variables": ["A", "B"],
  "series": [{ "name": "样本", "data": [[1, 2]] }]
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
