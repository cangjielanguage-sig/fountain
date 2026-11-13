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
public class DensityChart_test {
    private func draw(json: String): String {
        DensityChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 两个系列，一个填充。 */
    @TestCase
    public func drawsTwoSeries(): Unit {
        let svg = draw("""
{
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [
    { "name": "2025", "data": [8, 9, 10, 11, 12, 13, 15, 18], "bandwidth": 2.0, "fill": true },
    { "name": "2026", "data": [9, 10, 12, 14, 16, 19, 22, 25], "bandwidth": 2.0, "fill": false }
  ]
}
""")
        @Assert(count(svg, "class=\"density-line\"") == 2)
        @Assert(count(svg, "class=\"density-area\"") == 1)
    }

    /** 高斯核密度取值。 */
    @TestCase
    public func computesKde(): Unit {
        let value = gaussianKde([0.0, 0.0], 1.0, 0.0)
        @Assert(abs(value - 0.3989422804) < 1e-9)
    }

    /** 缺省带宽仍能绘制。 */
    @TestCase
    public func usesDefaultBandwidth(): Unit {
        let svg = draw("""
{
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3, 4, 5] }]
}
""")
        @Assert(count(svg, "class=\"density-line\"") == 1)
    }

    /** 非法带宽。 */
    @TestCase
    public func rejectsNegativeBandwidth(): Unit {
        try {
            draw("""
{
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3], "bandwidth": -1 }]
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
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [] }]
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
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, "2", 3] }]
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
{ "type": "density" }
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
  "type": "histogram",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3] }]
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
  "type": "density",
  "xAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3, 4, 5], "bandwidth": 1.0 }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
