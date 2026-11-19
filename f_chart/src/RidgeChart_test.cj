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
public class RidgeChart_test {
    private func draw(json: String): String {
        RidgeChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "ridge",
  "xAxis": { "type": "linear", "title": "月收入" },
  "yAxis": { "type": "category", "labels": ["2023", "2024", "2025", "2026"] },
  "series": [
    { "name": "2023", "data": [6, 8, 9, 10, 11, 12, 14, 16, 18, 22], "overlap": 0.5 },
    { "name": "2024", "data": [7, 9, 10, 12, 13, 15, 17, 20, 23, 28], "overlap": 0.5 },
    { "name": "2025", "data": [8, 10, 12, 14, 16, 18, 21, 25, 30, 36], "overlap": 0.5 },
    { "name": "2026", "data": [10, 12, 15, 18, 21, 24, 28, 33, 40, 48], "overlap": 0.5 }
  ]
}
"""

    /** 四组四条山脊。 */
    @TestCase
    public func drawsRidges(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"ridge-area\"") == 4)
        @Assert(count(svg, "class=\"ridge-line\"") == 4)
        @Assert(count(svg, "class=\"ridge-label\"") == 4)
    }

    /** 标签来自 yAxis.labels。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("2023"))
        @Assert(svg.contains("2026"))
    }

    /** 重叠越大振幅越高。 */
    @TestCase
    public func amplitudeIncreases(): Unit {
        @Assert(ridgeAmplitude(100.0, 0.0) < ridgeAmplitude(100.0, 1.0))
        @Assert(abs(ridgeAmplitude(100.0, 0.5) - 100.0) < 1e-9)
    }

    /** 非法 overlap。 */
    @TestCase
    public func rejectsInvalidOverlap(): Unit {
        try {
            draw("""
{
  "type": "ridge",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "A", "data": [1, 2, 3], "overlap": 1.5 }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法带宽。 */
    @TestCase
    public func rejectsInvalidBandwidth(): Unit {
        try {
            draw("""
{
  "type": "ridge",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "A", "data": [1, 2, 3], "bandwidth": -1 }]
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
  "type": "ridge",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "A", "data": [] }]
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
  "type": "ridge",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "A", "data": [1, "2", 3] }]
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
{ "type": "ridge" }
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
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "A", "data": [1, 2, 3] }]
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
