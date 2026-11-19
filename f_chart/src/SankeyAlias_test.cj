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
public class SankeyAlias_test {
    private func draw(json: String): String {
        SankeyChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "sankey",
  "title": "流量来源",
  "width": 760,
  "height": 480,
  "nodeWidth": 16,
  "nodeGap": 12,
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

    /** M67 别名复用 SankeyChart。 */
    @TestCase
    public func drawsDocumentedAlias(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("<svg"))
        @Assert(svg.contains("class=\"sankey-link\""))
        @Assert(svg.contains("class=\"sankey-node\""))
    }

    /** type=sankey 不抛 UnsupportedChart。 */
    @TestCase
    public func acceptsSankeyType(): Unit {
        let svg = draw("""
{
  "type": "sankey",
  "nodes": [
    { "id": "a", "name": "A" },
    { "id": "b", "name": "B" }
  ],
  "links": [ { "source": "a", "target": "b", "value": 1 } ]
}
""")
        @Assert(svg.contains("sankey-link"))
    }
}
