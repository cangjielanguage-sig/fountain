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
public class SankeyChart_test {
    private func draw(json: String): String {
        SankeyChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "sankey",
  "nodes": [
    { "id": "search", "name": "搜索" },
    { "id": "social", "name": "社交" },
    { "id": "home", "name": "首页" },
    { "id": "detail", "name": "详情" },
    { "id": "cart", "name": "购物车" },
    { "id": "pay", "name": "支付" }
  ],
  "links": [
    { "source": "search", "target": "home", "value": 400 },
    { "source": "social", "target": "home", "value": 300 },
    { "source": "home", "target": "detail", "value": 550 },
    { "source": "detail", "target": "cart", "value": 260 },
    { "source": "cart", "target": "pay", "value": 180 }
  ]
}
"""

    /** 六个节点、五条流量带。 */
    @TestCase
    public func drawsNodesAndLinks(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"sankey-node\"") == 6)
        @Assert(count(svg, "class=\"sankey-link\"") == 5)
        @Assert(count(svg, "class=\"sankey-label\"") == 6)
    }

    /** 最长路径分层。 */
    @TestCase
    public func computesLayers(): Unit {
        let layers = sankeyLayers(6, [0, 1, 2, 3, 4], [2, 2, 3, 4, 5])
        @Assert(layers.size == 6)
        @Assert(layers[0] == 0)
        @Assert(layers[1] == 0)
        @Assert(layers[2] == 1)
        @Assert(layers[3] == 2)
        @Assert(layers[4] == 3)
        @Assert(layers[5] == 4)
    }

    /** 悬空端点。 */
    @TestCase
    public func rejectsMissingEndpoint(): Unit {
        try {
            draw("""
{
  "type": "sankey",
  "nodes": [{ "id": "a", "name": "A" }],
  "links": [{ "source": "a", "target": "ghost", "value": 10 }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "sankey",
  "nodes": [{ "id": "a", "name": "A" }, { "id": "b", "name": "B" }],
  "links": [{ "source": "a", "target": "b", "value": -10 }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 nodes。 */
    @TestCase
    public func rejectsMissingNodes(): Unit {
        try {
            draw("""
{ "type": "sankey", "links": [] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 缺 links。 */
    @TestCase
    public func rejectsMissingLinks(): Unit {
        try {
            draw("""
{
  "type": "sankey",
  "nodes": [{ "id": "a", "name": "A" }]
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
  "type": "chord",
  "nodes": [{ "id": "a", "name": "A" }],
  "links": []
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
