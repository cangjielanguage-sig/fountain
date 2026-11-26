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
public class DotStripChart_test {
    private func draw(json: String): String {
        DotStripChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "dot-strip",
  "title": "各组小样本",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "linear", "title": "值", "min": 0 },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 24, 28, 31, 35], "jitter": 0.15, "dotSize": 7 }
  ]
}
"""

    /** 八个点。 */
    @TestCase
    public func drawsDots(): Unit {
        @Assert(count(draw(sample), "class=\"dot-strip-dot\"") == 8)
    }

    /** 类目名与轴。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("A"))
        @Assert(svg.contains("值"))
    }

    /** 抖动范围。 */
    @TestCase
    public func boundsJitter(): Unit {
        for (index in 0..8) {
            let offset = dotStripOffset(index, 0.15, 100.0)
            @Assert(abs(offset) <= 15.0 + 1e-9)
        }
    }

    /** 抖动确定且不同。 */
    @TestCase
    public func variesOffsets(): Unit {
        let first = dotStripOffset(0, 0.15, 100.0)
        let second = dotStripOffset(1, 0.15, 100.0)
        @Assert(first != second)
        @Assert(abs(dotStripOffset(0, 0.15, 100.0) - first) < 1e-9)
    }

    /** 负抖动。 */
    @TestCase
    public func rejectsNegativeJitter(): Unit {
        let json = """
{
  "type": "dot-strip",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1], "jitter": -0.1 }
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

    /** 非法点大小。 */
    @TestCase
    public func rejectsDotSize(): Unit {
        let json = """
{
  "type": "dot-strip",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1], "dotSize": 0 }
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

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "dot-strip",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [] }
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
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1] }
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
