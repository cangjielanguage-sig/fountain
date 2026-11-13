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
public class HistogramChart_test {
    private func draw(json: String): String {
        HistogramChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 八值四箱 → 四根柱。 */
    @TestCase
    public func drawsBars(): Unit {
        let svg = draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [{ "name": "样本", "data": [1, 2, 3, 4, 5, 6, 7, 8], "bins": 4 }]
}
""")
        @Assert(count(svg, "class=\"histogram-bar\"") == 4)
    }

    /** 均匀数据每箱两个。 */
    @TestCase
    public func computesCounts(): Unit {
        let bins = computeHistogram([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], 4)
        @Assert(bins.counts.size == 4)
        for (index in 0..4) {
            @Assert(bins.counts[index] == 2)
        }
    }

    /** 最大值归入最后一箱。 */
    @TestCase
    public func clampsMaxIntoLastBin(): Unit {
        let bins = computeHistogram([1.0, 1.0, 8.0], 2)
        @Assert(bins.counts[0] == 2)
        @Assert(bins.counts[1] == 1)
    }

    /** 零频箱不绘制。 */
    @TestCase
    public func skipsZeroBins(): Unit {
        let svg = draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [5, 5, 5, 5], "bins": 4 }]
}
""")
        @Assert(count(svg, "class=\"histogram-bar\"") == 1)
    }

    /** 数值轴刻度。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear", "title": "身高" },
  "yAxis": { "type": "linear", "title": "频数", "min": 0 },
  "series": [{ "name": "样本", "data": [1, 2, 3, 4, 5, 6, 7, 8], "bins": 4 }]
}
""")
        @Assert(count(svg, "class=\"tick-label\"") >= 2)
        @Assert(svg.contains("身高"))
        @Assert(svg.contains("频数"))
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "data": [1, 2, 3] },
    { "name": "乙", "data": [4, 5, 6] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** bins 为 0。 */
    @TestCase
    public func rejectsInvalidBins(): Unit {
        try {
            draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [1, 2, 3], "bins": 0 }]
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
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值数据。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [1, "2", 3] }]
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
{ "type": "histogram" }
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
  "xAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [1, 2, 3] }]
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
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [1, 2, 3, 4, 5], "bins": 3 }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
