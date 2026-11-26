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
public class EcdfChart_test {
    private func draw(json: String): String {
        EcdfChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "ecdf",
  "title": "响应时间累积分布",
  "xAxis": { "type": "linear", "title": "响应时间（ms）" },
  "yAxis": { "type": "linear", "title": "累积频率", "min": 0, "max": 1 },
  "series": [
    { "name": "优化前", "data": [120, 135, 150, 160, 175, 190, 210, 240, 280, 320] },
    { "name": "优化后", "data": [80, 90, 95, 100, 110, 120, 130, 145, 160, 180] }
  ]
}
"""

    /** 两条阶梯线。 */
    @TestCase
    public func drawsLines(): Unit {
        @Assert(count(draw(sample), "class=\"ecdf-line\"") == 2)
    }

    /** 图例与轴。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("优化前"))
        @Assert(svg.contains("优化后"))
        @Assert(svg.contains("累积频率"))
    }

    /** 排序与累计频率。 */
    @TestCase
    public func computesPoints(): Unit {
        let points = ecdfPoints([3.0, 1.0, 2.0])
        @Assert(points.size == 3)
        @Assert(abs(points[0][0] - 1.0) < 1e-9)
        @Assert(abs(points[0][1] - 1.0 / 3.0) < 1e-9)
        @Assert(abs(points[1][0] - 2.0) < 1e-9)
        @Assert(abs(points[1][1] - 2.0 / 3.0) < 1e-9)
        @Assert(abs(points[2][0] - 3.0) < 1e-9)
        @Assert(abs(points[2][1] - 1.0) < 1e-9)
    }

    /** 单点。 */
    @TestCase
    public func handlesSinglePoint(): Unit {
        let points = ecdfPoints([5.0])
        @Assert(points.size == 1)
        @Assert(abs(points[0][1] - 1.0) < 1e-9)
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "ecdf",
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
  "type": "density",
  "series": [
    { "name": "S", "data": [1, 2] }
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
