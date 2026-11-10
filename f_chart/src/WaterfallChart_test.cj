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
public class WaterfallChart_test {
    private func draw(json: String): String {
        WaterfallChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "waterfall",
  "xAxis": { "type": "category", "labels": ["期初", "收入", "成本", "税费", "期末"] },
  "yAxis": { "type": "linear", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "利润",
      "data": [
        { "name": "期初", "value": 120, "type": "total" },
        { "name": "收入", "value": 80, "type": "increase" },
        { "name": "成本", "value": -45, "type": "decrease" },
        { "name": "税费", "value": -15, "type": "decrease" },
        { "name": "期末", "value": 140, "type": "total" }
      ]
    }
  ]
}
"""

    /** 五种台阶 + 四类柱。 */
    @TestCase
    public func drawsBarsByType(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"waterfall-bar") == 5)
        @Assert(count(svg, "waterfall-total") == 2)
        @Assert(count(svg, "waterfall-increase") == 1)
        @Assert(count(svg, "waterfall-decrease") == 2)
    }

    /** 四根连接器。 */
    @TestCase
    public func drawsConnectors(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"connector\"") == 4)
    }

    /** 每根柱有数值标签。 */
    @TestCase
    public func drawsBarLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"bar-label\"") == 5)
        @Assert(svg.contains("期初"))
        @Assert(svg.contains("期末"))
    }

    /** 累计：increase 从累计到累计+value，total 重置。 */
    @TestCase
    public func computesSpans(): Unit {
        let increased = waterfallSpan("increase", 80.0, 120.0)
        @Assert(increased[0] == 120.0)
        @Assert(increased[1] == 200.0)
        let decreased = waterfallSpan("decrease", -45.0, 200.0)
        @Assert(decreased[0] == 200.0)
        @Assert(decreased[1] == 155.0)
        let total = waterfallSpan("total", 140.0, 999.0)
        @Assert(total[0] == 0.0)
        @Assert(total[1] == 140.0)
    }

    /** 范围覆盖 0 与所有端点。 */
    @TestCase
    public func computesBounds(): Unit {
        let bounds = waterfallBounds(
            [0.0, 120.0, 200.0, 155.0],
            [120.0, 200.0, 155.0, 140.0]
        )
        @Assert(bounds[0] == 0.0)
        @Assert(bounds[1] == 200.0)
        let negative = waterfallBounds([0.0, 20.0], [20.0, -10.0])
        @Assert(negative[0] == -10.0)
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "waterfall",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "甲", "data": [{ "value": 10, "type": "total" }] },
    { "name": "乙", "data": [{ "value": 5, "type": "total" }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** value 非数值。 */
    @TestCase
    public func rejectsNonNumericValue(): Unit {
        try {
            draw("""
{
  "type": "waterfall",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "甲", "data": [{ "value": "10", "type": "total" }] }]
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
{ "type": "waterfall" }
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
  "series": [{ "name": "甲", "data": [{ "value": 10, "type": "total" }] }]
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
