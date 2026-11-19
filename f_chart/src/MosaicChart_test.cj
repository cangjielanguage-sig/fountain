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
public class MosaicChart_test {
    private func draw(json: String): String {
        MosaicChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "mosaic",
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北", "西部"] },
  "series": [
    { "name": "购买", "data": [120, 90, 70, 50] },
    { "name": "未购买", "data": [80, 70, 60, 40] }
  ]
}
"""

    /** 四列两系列 → 八个单元。 */
    @TestCase
    public func drawsCells(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"mosaic-cell\"") == 8)
        @Assert(count(svg, "class=\"mosaic-label\"") == 4)
    }

    /** 列总和。 */
    @TestCase
    public func computesColumnTotals(): Unit {
        let totals = mosaicColumnTotals(
            [[120.0, 90.0, 70.0, 50.0], [80.0, 70.0, 60.0, 40.0]],
            4
        )
        @Assert(totals.size == 4)
        @Assert(totals[0] == 200.0)
        @Assert(totals[1] == 160.0)
        @Assert(totals[2] == 130.0)
        @Assert(totals[3] == 90.0)
    }

    /** 类别标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("华东"))
        @Assert(svg.contains("西部"))
    }

    /** 长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "mosaic",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "甲", "data": [1, 2, 3] },
    { "name": "乙", "data": [1, 2] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "mosaic",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "甲", "data": [1, -5] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 总和为零。 */
    @TestCase
    public func rejectsZeroTotal(): Unit {
        try {
            draw("""
{
  "type": "mosaic",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "甲", "data": [0, 0] }]
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
  "type": "mosaic",
  "xAxis": { "type": "category", "labels": ["A"] }
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
  "type": "funnel",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [1] }]
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
