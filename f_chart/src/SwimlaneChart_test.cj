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
public class SwimlaneChart_test {
    private func draw(json: String): String {
        SwimlaneChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "swimlane",
  "title": "审批流程",
  "width": 900,
  "height": 560,
  "direction": "horizontal",
  "lanes": [
    { "id": "employee", "name": "员工" },
    { "id": "manager", "name": "主管" },
    { "id": "finance", "name": "财务" }
  ],
  "nodes": [
    { "id": "submit", "label": "提交申请", "lane": "employee" },
    { "id": "review", "label": "主管审批", "lane": "manager" },
    { "id": "pay", "label": "财务打款", "lane": "finance" },
    { "id": "reject", "label": "驳回", "lane": "manager" }
  ],
  "edges": [
    { "source": "submit", "target": "review" },
    { "source": "review", "target": "pay", "label": "通过" },
    { "source": "review", "target": "reject", "label": "不通过" }
  ]
}
"""

    /** 三条泳道。 */
    @TestCase
    public func drawsLanes(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"swimlane-lane\"") == 3)
        @Assert(count(svg, "class=\"swimlane-label\"") == 3)
    }

    /** 四个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"swimlane-node\"") == 4)
        @Assert(count(svg, "class=\"swimlane-node-label\"") == 4)
        @Assert(svg.contains("提交申请"))
    }

    /** 三条连线。 */
    @TestCase
    public func drawsEdges(): Unit {
        @Assert(count(draw(sample), "class=\"swimlane-edge\"") == 3)
    }

    /** 连线标签。 */
    @TestCase
    public func drawsEdgeLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"swimlane-edge-label\"") == 2)
        @Assert(svg.contains("通过"))
    }

    /** 垂直布局。 */
    @TestCase
    public func drawsVertical(): Unit {
        let json = """
{
  "type": "swimlane",
  "direction": "vertical",
  "lanes": [
    { "id": "a", "name": "甲" },
    { "id": "b", "name": "乙" }
  ],
  "nodes": [
    { "id": "n1", "label": "开始", "lane": "a" },
    { "id": "n2", "label": "结束", "lane": "b" }
  ],
  "edges": [
    { "source": "n1", "target": "n2" }
  ]
}
"""
        let svg = draw(json)
        @Assert(count(svg, "class=\"swimlane-node\"") == 2)
        @Assert(count(svg, "class=\"swimlane-edge\"") == 1)
    }

    /** 未知泳道。 */
    @TestCase
    public func rejectsUnknownLane(): Unit {
        let json = """
{
  "type": "swimlane",
  "lanes": [ { "id": "a", "name": "甲" } ],
  "nodes": [ { "id": "n1", "label": "开始", "lane": "ghost" } ],
  "edges": []
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 未知端点。 */
    @TestCase
    public func rejectsUnknownEndpoint(): Unit {
        let json = """
{
  "type": "swimlane",
  "lanes": [ { "id": "a", "name": "甲" } ],
  "nodes": [ { "id": "n1", "label": "开始", "lane": "a" } ],
  "edges": [ { "source": "n1", "target": "ghost" } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法方向。 */
    @TestCase
    public func rejectsDirection(): Unit {
        let json = """
{
  "type": "swimlane",
  "direction": "diagonal",
  "lanes": [ { "id": "a", "name": "甲" } ],
  "nodes": [ { "id": "n1", "label": "开始", "lane": "a" } ],
  "edges": []
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
  "type": "flowchart",
  "lanes": [ { "id": "a", "name": "甲" } ],
  "nodes": [ { "id": "n1", "label": "开始", "lane": "a" } ],
  "edges": []
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
