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
public class StreamgraphChart_test {
    private func draw(json: String): String {
        StreamgraphChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "streamgraph",
  "title": "音乐流派热度",
  "xAxis": { "type": "category", "labels": ["2019", "2020", "2021", "2022", "2023", "2024"] },
  "yAxis": { "type": "linear", "grid": false },
  "baseline": "wiggle",
  "series": [
    { "name": "流行", "data": [40, 45, 50, 48, 55, 60] },
    { "name": "摇滚", "data": [30, 28, 25, 27, 24, 22] },
    { "name": "电子", "data": [15, 20, 28, 35, 40, 45] },
    { "name": "民谣", "data": [10, 12, 14, 13, 16, 18] }
  ]
}
"""

    /** 四条色带。 */
    @TestCase
    public func drawsBands(): Unit {
        @Assert(count(draw(sample), "class=\"stream-band\"") == 4)
    }

    /** 图例包含四个系列。 */
    @TestCase
    public func drawsLegend(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("流行"))
        @Assert(svg.contains("民谣"))
    }

    /** 零基线。 */
    @TestCase
    public func zeroBaseline(): Unit {
        let baseline = streamBaseline([10.0, 20.0], "zero")
        @Assert(baseline.size == 2)
        @Assert(abs(baseline[0]) < 1e-9)
        @Assert(abs(baseline[1]) < 1e-9)
    }

    /** 对称基线。 */
    @TestCase
    public func symmetryBaseline(): Unit {
        let baseline = streamBaseline([10.0, 20.0], "symmetry")
        @Assert(abs(baseline[0] + 5.0) < 1e-9)
        @Assert(abs(baseline[1] + 10.0) < 1e-9)
    }

    /** wiggle 基线平滑且长度一致。 */
    @TestCase
    public func wiggleBaseline(): Unit {
        let baseline = streamBaseline([10.0, 20.0, 10.0], "wiggle")
        @Assert(baseline.size == 3)
        @Assert(abs(baseline[0] + 5.0) < 1e-9)
        @Assert(abs(baseline[1] + 7.5) < 1e-9)
        @Assert(abs(baseline[2] + 5.0) < 1e-9)
    }

    /** 非法基线。 */
    @TestCase
    public func rejectsBaseline(): Unit {
        let json = """
{
  "type": "streamgraph",
  "baseline": "center",
  "series": [
    { "name": "A", "data": [1, 2] }
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

    /** 长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        let json = """
{
  "type": "streamgraph",
  "series": [
    { "name": "A", "data": [1, 2, 3] },
    { "name": "B", "data": [1, 2, 3, 4] }
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
  "type": "stacked-area",
  "series": [
    { "name": "A", "data": [1, 2] }
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
