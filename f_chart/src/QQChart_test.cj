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
public class QQChart_test {
    private func draw(json: String): String {
        QQChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 五个样本五个点、一条参考线。 */
    @TestCase
    public func drawsPointsAndLine(): Unit {
        let svg = draw("""
{
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [12, 15, 18, 20, 22], "distribution": "normal", "showLine": true }]
}
""")
        @Assert(count(svg, "class=\"qq-point\"") == 5)
        @Assert(count(svg, "class=\"qq-line\"") == 1)
    }

    /** showLine 关闭。 */
    @TestCase
    public func hidesLine(): Unit {
        let svg = draw("""
{
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3], "showLine": false }]
}
""")
        @Assert(count(svg, "class=\"qq-point\"") == 3)
        @Assert(count(svg, "class=\"qq-line\"") == 0)
    }

    /** 标准正态分位点。 */
    @TestCase
    public func computesNormalQuantile(): Unit {
        @Assert(abs(normalQuantile(0.5)) < 1e-6)
        @Assert(abs(normalQuantile(0.975) - 1.959964) < 1e-4)
    }

    /** 均匀分布理论分位点。 */
    @TestCase
    public func computesUniformQuantiles(): Unit {
        let quantiles = qqTheoryQuantiles(4, "uniform")
        @Assert(quantiles.size == 4)
        @Assert(abs(quantiles[0] - 0.125) < 1e-9)
        @Assert(abs(quantiles[1] - 0.375) < 1e-9)
        @Assert(abs(quantiles[2] - 0.625) < 1e-9)
        @Assert(abs(quantiles[3] - 0.875) < 1e-9)
    }

    /** 指数分布理论分位点。 */
    @TestCase
    public func computesExponentialQuantiles(): Unit {
        let quantiles = qqTheoryQuantiles(2, "exponential")
        @Assert(abs(quantiles[0] - 0.2876821) < 1e-6)
        @Assert(abs(quantiles[1] - 1.3862944) < 1e-6)
    }

    /** 非法分布。 */
    @TestCase
    public func rejectsInvalidDistribution(): Unit {
        try {
            draw("""
{
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3], "distribution": "beta" }]
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
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
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
{ "type": "qq" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "data": [1, 2, 3] },
    { "name": "乙", "data": [2, 3, 4] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
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
  "type": "qq",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "样本", "data": [1, 2, 3, 4, 5] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
