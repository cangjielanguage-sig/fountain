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
public class ParetoChart_test {
    private func draw(json: String): String {
        ParetoChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "pareto",
  "xAxis": { "type": "category", "labels": ["外观", "尺寸", "装配", "功能", "包装", "其他"] },
  "yAxis": { "type": "linear", "min": 0 },
  "showCumulative": true,
  "series": [{ "name": "缺陷数", "data": [120, 80, 55, 30, 12, 8] }]
}
"""

    /** 六根柱、一条累计线、六个点。 */
    @TestCase
    public func drawsBarsAndLine(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pareto-bar\"") == 6)
        @Assert(count(svg, "class=\"pareto-line\"") == 1)
        @Assert(count(svg, "class=\"pareto-point\"") == 6)
    }

    /** 关闭累计线。 */
    @TestCase
    public func hidesCumulative(): Unit {
        let svg = draw("""
{
  "type": "pareto",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "showCumulative": false,
  "series": [{ "name": "缺陷数", "data": [5, 3, 1] }]
}
""")
        @Assert(count(svg, "class=\"pareto-bar\"") == 3)
        @Assert(count(svg, "class=\"pareto-line\"") == 0)
        @Assert(count(svg, "class=\"pareto-point\"") == 0)
    }

    /** 降序下标。 */
    @TestCase
    public func sortsDescending(): Unit {
        let order = paretoOrder([30.0, 120.0, 80.0])
        @Assert(order[0] == 1)
        @Assert(order[1] == 2)
        @Assert(order[2] == 0)
    }

    /** 累计百分比。 */
    @TestCase
    public func computesCumulative(): Unit {
        let cumulative = paretoCumulative([120.0, 80.0, 55.0, 30.0, 12.0, 8.0])
        @Assert(cumulative.size == 6)
        @Assert(abs(cumulative[0] - 39.34426229508197) < 1e-9)
        @Assert(abs(cumulative[5] - 100.0) < 1e-9)
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "pareto",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "缺陷数", "data": [-5] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 标签长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "pareto",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [{ "name": "缺陷数", "data": [5, 3, 1, 1] }]
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
  "type": "pareto",
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
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "缺陷数", "data": [5] }]
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
