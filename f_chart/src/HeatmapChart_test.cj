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
public class HeatmapChart_test {
    private func draw(json: String): String {
        HeatmapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "heatmap",
  "title": "周活跃热力",
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "category", "labels": ["上午", "下午", "晚上"] },
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showValues": true,
  "series": [
    {
      "name": "活跃度",
      "data": [
        [12, 18, 20, 17, 25],
        [22, 28, 30, 26, 35],
        [30, 36, 32, 28, 40]
      ]
    }
  ]
}
"""

    /** 三行五列共 15 个单元格。 */
    @TestCase
    public func drawsCells(): Unit {
        @Assert(count(draw(sample), "class=\"heatmap-cell\"") == 15)
    }

    /** showValues 为 true 时每个单元格一个数值标签。 */
    @TestCase
    public func drawsValues(): Unit {
        @Assert(count(draw(sample), "class=\"heatmap-value\"") == 15)
    }

    /** 默认不显示数值。 */
    @TestCase
    public func hidesValuesByDefault(): Unit {
        let svg = draw("""
{
  "type": "heatmap",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "category", "labels": ["R"] },
  "series": [ { "name": "值", "data": [ [1, 2] ] } ]
}
""")
        @Assert(count(svg, "class=\"heatmap-cell\"") == 2)
        @Assert(count(svg, "class=\"heatmap-value\"") == 0)
    }

    /** 自定义三色用于最值单元格。 */
    @TestCase
    public func usesColorRange(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("#e8f1fb"))
        @Assert(svg.contains("#1f4e79"))
    }

    /** 三色插值端点与中点。 */
    @TestCase
    public func interpolatesColors(): Unit {
        let low = "#e8f1fb"
        let mid = "#7fb3d5"
        let high = "#1f4e79"
        @Assert(heatmapColor(0.0, low, mid, high) == low)
        @Assert(heatmapColor(0.5, low, mid, high) == mid)
        @Assert(heatmapColor(1.0, low, mid, high) == high)
    }

    /** 行长度不一致。 */
    @TestCase
    public func rejectsRaggedMatrix(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "series": [ { "name": "值", "data": [ [1, 2, 3], [4, 5] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 列标签数量不匹配。 */
    @TestCase
    public func rejectsColumnLabelMismatch(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "yAxis": { "type": "category", "labels": ["R"] },
  "series": [ { "name": "值", "data": [ [1, 2, 3] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 行标签数量不匹配。 */
    @TestCase
    public func rejectsRowLabelMismatch(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "xAxis": { "type": "category", "labels": ["A"] },
  "yAxis": { "type": "category", "labels": ["R1", "R2"] },
  "series": [ { "name": "值", "data": [ [1] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字元素。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "series": [ { "name": "值", "data": [ [1, "a"] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负 cellGap。 */
    @TestCase
    public func rejectsNegativeGap(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "cellGap": -1,
  "series": [ { "name": "值", "data": [ [1] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空矩阵。 */
    @TestCase
    public func rejectsEmptyMatrix(): Unit {
        try {
            draw("""
{
  "type": "heatmap",
  "series": [ { "name": "值", "data": [] } ]
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
{ "type": "heatmap" }
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
  "type": "bar",
  "series": [ { "name": "值", "data": [ [1] ] } ]
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
