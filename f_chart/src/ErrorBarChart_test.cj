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
public class ErrorBarChart_test {
    private func draw(json: String): String {
        ErrorBarChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "error-bar",
  "title": "各组均值与置信区间",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "yAxis": { "type": "linear", "title": "均值", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "均值",
      "data": [
        { "x": "A", "y": 12.0, "low": 10.5, "high": 13.5 },
        { "x": "B", "y": 15.0, "low": 13.2, "high": 16.8 },
        { "x": "C", "y": 11.0, "low": 9.0, "high": 13.0 },
        { "x": "D", "y": 18.0, "low": 16.5, "high": 19.5 }
      ]
    }
  ]
}
"""

    /** 四组：四条竖线、八个端帽、四个中心点。 */
    @TestCase
    public func drawsGroups(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"error-bar-line\"") == 4)
        @Assert(count(svg, "class=\"error-bar-cap\"") == 8)
        @Assert(count(svg, "class=\"error-bar-point\"") == 4)
    }

    /** 未给标签时按数据出现顺序生成类目。 */
    @TestCase
    public func usesDataOrder(): Unit {
        let svg = draw("""
{
  "type": "error-bar",
  "legend": { "show": false },
  "series": [
    { "name": "均值", "data": [
      { "x": "甲", "y": 5, "low": 4, "high": 6 },
      { "x": "乙", "y": 6, "low": 5, "high": 7 }
    ] }
  ]
}
""")
        @Assert(count(svg, "class=\"error-bar-line\"") == 2)
        @Assert(svg.contains("甲"))
        @Assert(svg.contains("乙"))
    }

    /** 线性 x 轴。 */
    @TestCase
    public func supportsNumericX(): Unit {
        let svg = draw("""
{
  "type": "error-bar",
  "xAxis": { "type": "linear", "title": "剂量" },
  "legend": { "show": false },
  "series": [
    { "name": "响应", "data": [
      { "x": 10, "y": 5, "low": 4, "high": 6 },
      { "x": 20, "y": 7, "low": 6, "high": 8 }
    ] }
  ]
}
""")
        @Assert(count(svg, "class=\"error-bar-line\"") == 2)
        @Assert(count(svg, "class=\"error-bar-point\"") == 2)
    }

    /** 时间 x 轴。 */
    @TestCase
    public func supportsTimeX(): Unit {
        let svg = draw("""
{
  "type": "error-bar",
  "xAxis": { "type": "time" },
  "legend": { "show": false },
  "series": [
    { "name": "响应", "data": [
      { "x": "2026-01-01", "y": 5, "low": 4, "high": 6 },
      { "x": "2026-01-02", "y": 6, "low": 5, "high": 7 }
    ] }
  ]
}
""")
        @Assert(count(svg, "class=\"error-bar-line\"") == 2)
    }

    /** 未知类目。 */
    @TestCase
    public func rejectsUnknownCategory(): Unit {
        try {
            draw("""
{
  "type": "error-bar",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "legend": { "show": false },
  "series": [ { "name": "均值", "data": [ { "x": "C", "y": 5, "low": 4, "high": 6 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 上下界倒置。 */
    @TestCase
    public func rejectsInvertedBounds(): Unit {
        try {
            draw("""
{
  "type": "error-bar",
  "legend": { "show": false },
  "series": [ { "name": "均值", "data": [ { "x": "A", "y": 5, "low": 6, "high": 3 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 中心值越界。 */
    @TestCase
    public func rejectsCenterOutsideBounds(): Unit {
        try {
            draw("""
{
  "type": "error-bar",
  "legend": { "show": false },
  "series": [ { "name": "均值", "data": [ { "x": "A", "y": 1, "low": 2, "high": 4 } ] } ]
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
  "type": "error-bar",
  "legend": { "show": false },
  "series": [ { "name": "均值", "data": [] } ]
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
{ "type": "error-bar" }
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
  "series": [ { "name": "均值", "data": [] } ]
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
