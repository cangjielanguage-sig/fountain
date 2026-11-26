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
public class BoxScatterChart_test {
    private func draw(json: String): String {
        BoxScatterChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "box-scatter",
  "title": "分布与原始点",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [12, 14, 15, 17, 19, 22, 25, 28, 31, 35], "showBox": true, "jitter": 0.2 }
  ]
}
"""

    /** 单组：箱体、须线、端帽与十个原始点。 */
    @TestCase
    public func drawsBoxAndPoints(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"box-scatter-point\"") == 10)
        @Assert(count(svg, "class=\"box-scatter-box\"") == 1)
        @Assert(count(svg, "class=\"box-scatter-median\"") == 1)
        @Assert(count(svg, "class=\"box-scatter-whisker\"") == 1)
        @Assert(count(svg, "class=\"box-scatter-cap\"") == 2)
    }

    /** 关闭箱体时只保留散点。 */
    @TestCase
    public func hidesBox(): Unit {
        let svg = draw("""
{
  "type": "box-scatter",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3, 4], "showBox": false } ]
}
""")
        @Assert(count(svg, "class=\"box-scatter-point\"") == 4)
        @Assert(count(svg, "class=\"box-scatter-box\"") == 0)
        @Assert(count(svg, "class=\"box-scatter-whisker\"") == 0)
        @Assert(count(svg, "class=\"box-scatter-cap\"") == 0)
    }

    /** 嵌套数组每组一个箱体。 */
    @TestCase
    public func drawsNestedGroups(): Unit {
        let svg = draw("""
{
  "type": "box-scatter",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [[1, 2, 3], [4, 5, 6]] } ]
}
""")
        @Assert(count(svg, "class=\"box-scatter-box\"") == 2)
        @Assert(count(svg, "class=\"box-scatter-point\"") == 6)
    }

    /** 五数概括（须线取 1.5 IQR 栅栏内最值）。 */
    @TestCase
    public func computesBounds(): Unit {
        let bounds = boxScatterBounds([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0])
        @Assert(bounds.size == 5)
        @Assert(abs(bounds[0] - 1.0) < 1e-9)
        @Assert(abs(bounds[1] - 3.0) < 1e-9)
        @Assert(abs(bounds[2] - 5.0) < 1e-9)
        @Assert(abs(bounds[3] - 7.0) < 1e-9)
        @Assert(abs(bounds[4] - 10.0) < 1e-9)
    }

    /** 组数与标签不一致。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        try {
            draw("""
{
  "type": "box-scatter",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [ { "name": "值", "data": [[1, 2], [3, 4]] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 抖动超出 0–1。 */
    @TestCase
    public func rejectsInvalidJitter(): Unit {
        try {
            draw("""
{
  "type": "box-scatter",
  "legend": { "show": false },
  "series": [ { "name": "值", "data": [1, 2, 3], "jitter": 1.5 } ]
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
  "type": "box-scatter",
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
  "type": "box-scatter",
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
  "type": "box-scatter",
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
{ "type": "box-scatter" }
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
  "type": "boxplot",
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
