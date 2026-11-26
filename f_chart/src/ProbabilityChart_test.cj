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
public class ProbabilityChart_test {
    private func draw(json: String): String {
        ProbabilityChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "probability",
  "title": "正态概率图",
  "xAxis": { "type": "linear", "title": "理论分位数" },
  "yAxis": { "type": "linear", "title": "样本分位数" },
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
"""

    /** 十一个散点与一条参考线。 */
    @TestCase
    public func drawsPointsAndLine(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"probability-point\"") == 11)
        @Assert(count(svg, "class=\"probability-line\"") == 1)
    }

    /** 关闭参考线。 */
    @TestCase
    public func hidesLine(): Unit {
        let svg = draw("""
{
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [1, 2, 3], "showLine": false } ]
}
""")
        @Assert(count(svg, "class=\"probability-point\"") == 3)
        @Assert(count(svg, "class=\"probability-line\"") == 0)
    }

    /** 均匀分布。 */
    @TestCase
    public func supportsUniform(): Unit {
        let svg = draw("""
{
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [1, 2, 3, 4], "distribution": "uniform" } ]
}
""")
        @Assert(count(svg, "class=\"probability-point\"") == 4)
        @Assert(count(svg, "class=\"probability-line\"") == 1)
    }

    /** 指数分布。 */
    @TestCase
    public func supportsExponential(): Unit {
        let svg = draw("""
{
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [1, 2, 3, 4], "distribution": "exponential" } ]
}
""")
        @Assert(count(svg, "class=\"probability-point\"") == 4)
    }

    /** 未知分布。 */
    @TestCase
    public func rejectsUnknownDistribution(): Unit {
        try {
            draw("""
{
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [1, 2, 3], "distribution": "poisson" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字样本。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [1, "a"] } ]
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
  "type": "probability",
  "legend": { "show": false },
  "series": [ { "name": "样本", "data": [] } ]
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
{ "type": "probability" }
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
  "type": "qq",
  "series": [ { "name": "样本", "data": [] } ]
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
