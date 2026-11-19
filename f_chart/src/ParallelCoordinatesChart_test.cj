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
public class ParallelCoordinatesChart_test {
    private func draw(json: String): String {
        ParallelCoordinatesChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "parallel-coordinates",
  "dimensions": [
    { "name": "价格", "min": 0, "max": 60 },
    { "name": "油耗", "min": 0, "max": 20 },
    { "name": "马力", "min": 0, "max": 400 },
    { "name": "空间", "min": 0, "max": 10 }
  ],
  "series": [
    { "name": "轿车", "data": [[25, 7, 180, 6], [18, 6, 150, 5], [40, 9, 300, 7]] },
    { "name": "SUV", "data": [[35, 12, 250, 9], [50, 14, 350, 10]] }
  ]
}
"""

    /** 四条维度轴与五个样本折线。 */
    @TestCase
    public func drawsAxesAndLines(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"dimension-axis\"") == 4)
        @Assert(count(svg, "class=\"dimension-label\"") == 4)
        @Assert(count(svg, "class=\"parallel-line\"") == 5)
    }

    /** 归一化与钳制。 */
    @TestCase
    public func normalizesValues(): Unit {
        @Assert(parallelNormalize(0.0, 0.0, 10.0) == 0.0)
        @Assert(parallelNormalize(10.0, 0.0, 10.0) == 1.0)
        @Assert(parallelNormalize(5.0, 0.0, 10.0) == 0.5)
        @Assert(parallelNormalize(-5.0, 0.0, 10.0) == 0.0)
        @Assert(parallelNormalize(15.0, 0.0, 10.0) == 1.0)
    }

    /** 维度范围缺省时从数据推导。 */
    @TestCase
    public func infersRanges(): Unit {
        let svg = draw("""
{
  "type": "parallel-coordinates",
  "dimensions": [{ "name": "A" }, { "name": "B" }],
  "series": [{ "name": "组", "data": [[1, 10], [5, 20]] }]
}
""")
        @Assert(count(svg, "class=\"parallel-line\"") == 2)
        @Assert(count(svg, "class=\"dimension-axis\"") == 2)
    }

    /** 行长度不匹配。 */
    @TestCase
    public func rejectsRowLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "parallel-coordinates",
  "dimensions": [
    { "name": "A", "min": 0, "max": 10 },
    { "name": "B", "min": 0, "max": 10 },
    { "name": "C", "min": 0, "max": 10 },
    { "name": "D", "min": 0, "max": 10 }
  ],
  "series": [{ "name": "组", "data": [[1, 2, 3]] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法维度范围。 */
    @TestCase
    public func rejectsInvalidRange(): Unit {
        try {
            draw("""
{
  "type": "parallel-coordinates",
  "dimensions": [{ "name": "A", "min": 5, "max": 5 }],
  "series": [{ "name": "组", "data": [[5]] }]
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
  "type": "parallel-coordinates",
  "dimensions": [{ "name": "A", "min": 0, "max": 10 }],
  "series": [{ "name": "组", "data": [["5"]] }]
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
  "type": "parallel-coordinates",
  "dimensions": [{ "name": "A", "min": 0, "max": 10 }]
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
  "type": "radar",
  "dimensions": [{ "name": "A", "min": 0, "max": 10 }],
  "series": [{ "name": "组", "data": [[5]] }]
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
