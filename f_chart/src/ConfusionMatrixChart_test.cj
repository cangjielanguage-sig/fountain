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
public class ConfusionMatrixChart_test {
    private func draw(json: String): String {
        ConfusionMatrixChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "confusion-matrix",
  "title": "分类混淆矩阵",
  "width": 560,
  "height": 560,
  "labels": ["猫", "狗", "鸟"],
  "normalize": "row",
  "showValues": true,
  "series": [
    {
      "name": "样本数",
      "data": [
        [45, 3, 2],
        [4, 38, 8],
        [1, 6, 33]
      ]
    }
  ]
}
"""

    /** 九个方格。 */
    @TestCase
    public func drawsCells(): Unit {
        @Assert(count(draw(sample), "class=\"confusion-cell\"") == 9)
    }

    /** 六个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"confusion-label\"") == 6)
        @Assert(svg.contains("猫"))
    }

    /** 九个数值。 */
    @TestCase
    public func drawsValues(): Unit {
        @Assert(count(draw(sample), "class=\"confusion-value\"") == 9)
    }

    /** 行归一化。 */
    @TestCase
    public func normalizesRows(): Unit {
        let normalized = confusionNormalize([[1.0, 1.0], [2.0, 0.0]], "row")
        @Assert(abs(normalized[0][0] - 0.5) < 1e-9)
        @Assert(abs(normalized[0][1] - 0.5) < 1e-9)
        @Assert(abs(normalized[1][0] - 1.0) < 1e-9)
        @Assert(abs(normalized[1][1]) < 1e-9)
    }

    /** 列归一化。 */
    @TestCase
    public func normalizesColumns(): Unit {
        let normalized = confusionNormalize([[1.0, 1.0], [2.0, 0.0]], "column")
        @Assert(abs(normalized[0][0] - 1.0 / 3.0) < 1e-9)
        @Assert(abs(normalized[0][1] - 1.0) < 1e-9)
        @Assert(abs(normalized[1][0] - 2.0 / 3.0) < 1e-9)
        @Assert(abs(normalized[1][1]) < 1e-9)
    }

    /** 不归一化。 */
    @TestCase
    public func keepsRawValues(): Unit {
        let normalized = confusionNormalize([[2.0, 4.0]], "none")
        @Assert(abs(normalized[0][0] - 2.0) < 1e-9)
        @Assert(abs(normalized[0][1] - 4.0) < 1e-9)
    }

    /** 非方阵。 */
    @TestCase
    public func rejectsNonSquare(): Unit {
        let json = """
{
  "type": "confusion-matrix",
  "labels": ["A", "B"],
  "series": [
    { "name": "S", "data": [ [1, 2, 3], [4, 5, 6] ] }
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

    /** 标签数量不符。 */
    @TestCase
    public func rejectsLabelCount(): Unit {
        let json = """
{
  "type": "confusion-matrix",
  "labels": ["A", "B"],
  "series": [
    { "name": "S", "data": [ [1, 2, 3], [4, 5, 6], [7, 8, 9] ] }
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

    /** 非法归一化模式。 */
    @TestCase
    public func rejectsNormalizeMode(): Unit {
        let json = """
{
  "type": "confusion-matrix",
  "labels": ["A"],
  "normalize": "all",
  "series": [
    { "name": "S", "data": [ [1] ] }
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
  "type": "heatmap",
  "labels": ["A"],
  "series": [
    { "name": "S", "data": [ [1] ] }
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
