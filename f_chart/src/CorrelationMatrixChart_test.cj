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
public class CorrelationMatrixChart_test {
    private func draw(json: String): String {
        CorrelationMatrixChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "yAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "method": "pearson",
  "showValues": true,
  "series": [
    {
      "name": "相关系数",
      "data": [
        [1.00, 0.81, 0.12, 0.08],
        [0.81, 1.00, 0.18, 0.15],
        [0.12, 0.18, 1.00, 0.42],
        [0.08, 0.15, 0.42, 1.00]
      ]
    }
  ]
}
"""

    /** 4×4 十六个单元。 */
    @TestCase
    public func drawsCells(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"correlation-cell\"") == 16)
    }

    /** 默认显示数值。 */
    @TestCase
    public func drawsValues(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"cell-value\"") == 16)
    }

    /** 关闭数值。 */
    @TestCase
    public func hidesValues(): Unit {
        let svg = draw("""
{
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "showValues": false,
  "series": [{ "name": "r", "data": [[1, 0.5], [0.5, 1]] }]
}
""")
        @Assert(count(svg, "class=\"cell-value\"") == 0)
        @Assert(count(svg, "class=\"correlation-cell\"") == 4)
    }

    /** 端点与中值配色。 */
    @TestCase
    public func mapsColors(): Unit {
        @Assert(correlationColor(-1.0, "#111111", "#222222", "#333333") == "#111111")
        @Assert(correlationColor(0.0, "#111111", "#222222", "#333333") == "#222222")
        @Assert(correlationColor(1.0, "#111111", "#222222", "#333333") == "#333333")
    }

    /** 非方阵。 */
    @TestCase
    public func rejectsNonSquare(): Unit {
        try {
            draw("""
{
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "r", "data": [[1, 0.5, 0.2], [0.5, 1, 0.1]] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 系数越界。 */
    @TestCase
    public func rejectsOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "r", "data": [[1, 1.5], [1.5, 1]] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 method。 */
    @TestCase
    public func rejectsInvalidMethod(): Unit {
        try {
            draw("""
{
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "category", "labels": ["A"] },
  "method": "kendall",
  "series": [{ "name": "r", "data": [[1]] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 标签长度不一致。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        try {
            draw("""
{
  "type": "correlation-matrix",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "r", "data": [[1, 0.5], [0.5, 1]] }]
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
{ "type": "correlation-matrix" }
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
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "r", "data": [[1]] }]
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
