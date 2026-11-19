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
public class BoxPlotChart_test {
    private func draw(json: String): String {
        BoxPlotChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["一班", "二班", "三班", "四班"] },
  "yAxis": { "type": "linear", "min": 0, "max": 100 },
  "legend": { "show": false },
  "series": [
    {
      "name": "成绩",
      "data": [
        { "name": "一班", "min": 55, "q1": 68, "median": 76, "q3": 85, "max": 96, "outliers": [42, 98] },
        { "name": "二班", "min": 60, "q1": 70, "median": 78, "q3": 86, "max": 94, "outliers": [] },
        { "name": "三班", "min": 50, "q1": 62, "median": 70, "q3": 80, "max": 90, "outliers": [35] },
        { "name": "四班", "min": 58, "q1": 72, "median": 82, "q3": 90, "max": 99 }
      ]
    }
  ]
}
"""

    /** 四个箱体、须、端帽与异常值。 */
    @TestCase
    public func drawsBoxes(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"box\"") == 4)
        @Assert(count(svg, "class=\"median\"") == 4)
        @Assert(count(svg, "class=\"whisker\"") == 8)
        @Assert(count(svg, "class=\"whisker-cap\"") == 8)
        @Assert(count(svg, "class=\"outlier\"") == 3)
    }

    /** 类别标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("一班"))
        @Assert(svg.contains("四班"))
    }

    /** q1 大于 median。 */
    @TestCase
    public func rejectsInvalidOrder(): Unit {
        try {
            draw("""
{
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "min": 10, "q1": 70, "median": 60, "q3": 80, "max": 90 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "min": 10, "q1": 20, "median": 30, "q3": 40, "max": 50 }] },
    { "name": "乙", "data": [{ "min": 10, "q1": 20, "median": 30, "q3": 40, "max": 50 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺少 q3。 */
    @TestCase
    public func rejectsMissingField(): Unit {
        try {
            draw("""
{
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "min": 10, "q1": 20, "median": 30, "max": 50 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 异常值非数值。 */
    @TestCase
    public func rejectsNonNumericOutlier(): Unit {
        try {
            draw("""
{
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "min": 10, "q1": 20, "median": 30, "q3": 40, "max": 50, "outliers": ["55"] }] }
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
  "type": "box-scatter",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "min": 10, "q1": 20, "median": 30, "q3": 40, "max": 50 }] }
  ]
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
