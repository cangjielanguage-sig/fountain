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
public class DecisionTreeChart_test {
    private func draw(json: String): String {
        DecisionTreeChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "decision-tree",
  "title": "决策树",
  "width": 900,
  "height": 520,
  "nodes": [
    { "id": "root", "label": "年龄 > 30?", "leaf": false },
    { "id": "left", "label": "收入 > 10k?", "parent": "root", "leaf": false },
    { "id": "right", "label": "通过", "parent": "root", "leaf": true },
    { "id": "ll", "label": "拒绝", "parent": "left", "leaf": true },
    { "id": "lr", "label": "通过", "parent": "left", "leaf": true }
  ],
  "edges": [
    { "source": "root", "target": "left", "label": "否" },
    { "source": "root", "target": "right", "label": "是" },
    { "source": "left", "target": "ll", "label": "否" },
    { "source": "left", "target": "lr", "label": "是" }
  ]
}
"""

    /** 五个节点：两个内部节点与三个叶子。 */
    @TestCase
    public func drawsNodes(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"decision-node\"") == 2)
        @Assert(count(svg, "class=\"decision-node decision-leaf\"") == 3)
    }

    /** 三个叶子。 */
    @TestCase
    public func marksLeaves(): Unit {
        @Assert(count(draw(sample), "decision-leaf") == 3)
    }

    /** 四条分支与标签。 */
    @TestCase
    public func drawsEdges(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"decision-edge\"") == 4)
        @Assert(count(svg, "class=\"decision-edge-label\"") == 4)
        @Assert(svg.contains("是"))
    }

    /** 节点文本。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"decision-node-label\"") == 5)
        @Assert(svg.contains("年龄 &gt; 30?"))
    }

    /** 父节点居中。 */
    @TestCase
    public func centersParent(): Unit {
        let root = DecisionNode("root", "根", false)
        let left = DecisionNode("left", "左", true)
        let right = DecisionNode("right", "右", true)
        root.children.add(left)
        root.children.add(right)
        let nodes: Array<DecisionNode> = [root, left, right]
        decisionTreeLayout(nodes, root, 140.0, 44.0, 70.0)
        @Assert(abs(root.slot - 0.5) < 1e-9)
        @Assert(left.y > root.y)
        @Assert(right.y > root.y)
    }

    /** 未知端点。 */
    @TestCase
    public func rejectsUnknownTarget(): Unit {
        let json = """
{
  "type": "decision-tree",
  "nodes": [
    { "id": "root", "label": "根" }
  ],
  "edges": [ { "source": "root", "target": "ghost" } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 多个根。 */
    @TestCase
    public func rejectsMultipleRoots(): Unit {
        let json = """
{
  "type": "decision-tree",
  "nodes": [
    { "id": "a", "label": "A" },
    { "id": "b", "label": "B" }
  ],
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
  "type": "org-chart",
  "nodes": [
    { "id": "a", "label": "A" }
  ],
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
