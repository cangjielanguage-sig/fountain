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
public class NodeLinkChart_test {
    private func draw(json: String): String {
        NodeLinkChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "node-link",
  "title": "服务依赖",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 120,
  "charge": -300,
  "nodes": [
    { "id": "gw", "name": "网关", "group": "接入" },
    { "id": "order", "name": "订单", "group": "业务" },
    { "id": "stock", "name": "库存", "group": "业务" },
    { "id": "pay", "name": "支付", "group": "业务" },
    { "id": "db", "name": "数据库", "group": "存储" }
  ],
  "links": [
    { "source": "gw", "target": "order", "value": 3 },
    { "source": "order", "target": "stock", "value": 2 },
    { "source": "order", "target": "pay", "value": 2 },
    { "source": "order", "target": "db", "value": 1 },
    { "source": "stock", "target": "db", "value": 1 }
  ]
}
"""

    /** 五个节点与五条连线。 */
    @TestCase
    public func drawsNodesAndEdges(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"node-link-node\"") == 5)
        @Assert(count(svg, "class=\"node-link-edge\"") == 5)
    }

    /** 节点标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("网关"))
        @Assert(svg.contains("数据库"))
    }

    /** 手工坐标布局。 */
    @TestCase
    public func supportsManualLayout(): Unit {
        let svg = draw("""
{
  "type": "node-link",
  "layout": "manual",
  "nodes": [
    { "id": "a", "name": "A", "x": 100, "y": 100 },
    { "id": "b", "name": "B", "x": 300, "y": 200 }
  ],
  "links": [ { "source": "a", "target": "b" } ]
}
""")
        @Assert(count(svg, "class=\"node-link-node\"") == 2)
        @Assert(count(svg, "class=\"node-link-edge\"") == 1)
    }

    /** 手工布局缺坐标。 */
    @TestCase
    public func rejectsManualMissingCoordinate(): Unit {
        try {
            draw("""
{
  "type": "node-link",
  "layout": "manual",
  "nodes": [
    { "id": "a", "name": "A", "x": 100, "y": 100 },
    { "id": "b", "name": "B", "x": 300 }
  ],
  "links": [ { "source": "a", "target": "b" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 非法布局。 */
    @TestCase
    public func rejectsInvalidLayout(): Unit {
        try {
            draw("""
{
  "type": "node-link",
  "layout": "grid",
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 未知端点。 */
    @TestCase
    public func rejectsUnknownEndpoint(): Unit {
        try {
            draw("""
{
  "type": "node-link",
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "missing" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 重复节点 id。 */
    @TestCase
    public func rejectsDuplicateNodeId(): Unit {
        try {
            draw("""
{
  "type": "node-link",
  "nodes": [ { "id": "a" }, { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空节点。 */
    @TestCase
    public func rejectsEmptyNodes(): Unit {
        try {
            draw("""
{
  "type": "node-link",
  "nodes": [],
  "links": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 连线宽度端点。 */
    @TestCase
    public func mapsEdgeWidth(): Unit {
        @Assert(abs(nodeLinkWidth(0.0, 10.0) - 1.0) < 1e-9)
        @Assert(abs(nodeLinkWidth(10.0, 10.0) - 4.0) < 1e-9)
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "arc",
  "nodes": [],
  "links": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 力导向布局确定性。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}
