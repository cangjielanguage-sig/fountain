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
public class WaterfallAlias_test {
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
  "title": "利润增减分解",
  "xAxis": { "type": "category", "labels": ["期初", "收入", "成本", "税费", "期末"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
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

    /** 五根柱。 */
    @TestCase
    public func drawsBars(): Unit {
        @Assert(count(draw(sample), "waterfall-bar") == 5)
    }

    /** 语义配色。 */
    @TestCase
    public func marksKinds(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "waterfall-total") == 2)
        @Assert(count(svg, "waterfall-increase") == 1)
        @Assert(count(svg, "waterfall-decrease") == 2)
    }

    /** 四条连接器。 */
    @TestCase
    public func drawsConnectors(): Unit {
        @Assert(count(draw(sample), "class=\"connector\"") == 4)
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "bar",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [ { "name": "A", "value": 1, "type": "total" } ] }
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
