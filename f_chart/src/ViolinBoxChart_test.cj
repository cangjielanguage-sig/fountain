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
public class ViolinBoxChart_test {
    private func draw(json: String): String {
        ViolinBoxChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "violin-box",
  "title": "分布、分位数与异常值",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [11, 13, 14, 16, 18, 20, 23, 26, 30, 36, 45], "bandwidth": 4.0, "showBox": true, "showOutliers": true }
  ]
}
"""

    /** 单组：轮廓、箱体、中位线、须线与两个端帽。 */
    @TestCase
    public func drawsViolinAndBox(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"violin-box-violin\"") == 1)
        @Assert(count(svg, "class=\"violin-box-box\"") == 1)
        @Assert(count(svg, "class=\"violin-box-median\"") == 1)
        @Assert(count(svg, "class=\"violin-box-whisker\"") == 1)
        @Assert(count(svg, "class=\"violin-box-cap\"") == 2)
    }

    /** 栅栏外的极端值。 */
    @TestCase
    public func drawsOutliers(): Unit {
        let svg = draw("""
{
  "type": "violin-box",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3, 4, 5, 6, 7, 8, 9, 100] } ]
}
""")
        @Assert(count(svg, "class=\"violin-box-outlier\"") == 1)
    }

    /** 关闭异常值。 */
    @TestCase
    public func hidesOutliers(): Unit {
        let svg = draw("""
{
  "type": "violin-box",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3, 4, 5, 6, 7, 8, 9, 100], "showOutliers": false } ]
}
""")
        @Assert(count(svg, "class=\"violin-box-outlier\"") == 0)
    }

    /** 关闭箱体只保留小提琴。 */
    @TestCase
    public func hidesBox(): Unit {
        let svg = draw("""
{
  "type": "violin-box",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3, 4, 5], "showBox": false } ]
}
""")
        @Assert(count(svg, "class=\"violin-box-violin\"") == 1)
        @Assert(count(svg, "class=\"violin-box-box\"") == 0)
        @Assert(count(svg, "class=\"violin-box-median\"") == 0)
        @Assert(count(svg, "class=\"violin-box-whisker\"") == 0)
    }

    /** 嵌套数组每组一个小提琴。 */
    @TestCase
    public func drawsNestedGroups(): Unit {
        let svg = draw("""
{
  "type": "violin-box",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [[1, 2, 3, 4], [5, 6, 7, 8]] } ]
}
""")
        @Assert(count(svg, "class=\"violin-box-violin\"") == 2)
        @Assert(count(svg, "class=\"violin-box-box\"") == 2)
    }

    /** 带宽必须大于 0。 */
    @TestCase
    public func rejectsInvalidBandwidth(): Unit {
        try {
            draw("""
{
  "type": "violin-box",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3], "bandwidth": 0 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 组数与标签不一致。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        try {
            draw("""
{
  "type": "violin-box",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [ { "name": "值", "data": [[1, 2], [3, 4]] } ]
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
  "type": "violin-box",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, "a"] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空组。 */
    @TestCase
    public func rejectsEmptyGroup(): Unit {
        try {
            draw("""
{
  "type": "violin-box",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [[1, 2], []] } ]
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
  "type": "violin-box",
  "legend": { "show": false },
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
{ "type": "violin-box" }
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
  "type": "violin",
  "series": [ { "name": "值", "data": [] } ]
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
