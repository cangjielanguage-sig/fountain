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
public class OrgChart_test {
    private func draw(json: String): String {
        OrgChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "org-chart",
  "title": "组织架构",
  "width": 900,
  "height": 560,
  "layout": "vertical",
  "nodeWidth": 140,
  "nodeHeight": 48,
  "levelGap": 80,
  "nodes": [
    { "id": "ceo", "name": "CEO", "parent": null },
    { "id": "cto", "name": "CTO", "parent": "ceo" },
    { "id": "cfo", "name": "CFO", "parent": "ceo" },
    { "id": "fe", "name": "前端组", "parent": "cto" },
    { "id": "be", "name": "后端组", "parent": "cto" },
    { "id": "fin", "name": "财务组", "parent": "cfo" }
  ]
}
"""

    /** 六个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        @Assert(count(draw(sample), "class=\"org-node\"") == 6)
    }

    /** 六个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"org-label\"") == 6)
        @Assert(svg.contains("前端组"))
    }

    /** 五条连线。 */
    @TestCase
    public func drawsLinks(): Unit {
        @Assert(count(draw(sample), "class=\"org-link\"") == 5)
    }

    /** 父节点槽位居中。 */
    @TestCase
    public func centersParent(): Unit {
        let root = OrgNode("root", "根", None)
        let left = OrgNode("left", "左", Some("root"))
        let right = OrgNode("right", "右", Some("root"))
        root.children.add(left)
        root.children.add(right)
        let nodes: Array<OrgNode> = [root, left, right]
        orgLayout(nodes, root, 100.0, 40.0, 80.0, false)
        @Assert(abs(root.slot - 0.5) < 1e-9)
        @Assert(abs(left.slot) < 1e-9)
        @Assert(abs(right.slot - 1.0) < 1e-9)
    }

    /** 垂直布局层级向下。 */
    @TestCase
    public func stacksVerticalLevels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("org-link"))
        let root = OrgNode("root", "根", None)
        let child = OrgNode("child", "子", Some("root"))
        root.children.add(child)
        let nodes: Array<OrgNode> = [root, child]
        orgLayout(nodes, root, 100.0, 40.0, 80.0, false)
        @Assert(child.y > root.y)
    }

    /** 水平布局层级向右。 */
    @TestCase
    public func movesHorizontal(): Unit {
        let root = OrgNode("root", "根", None)
        let child = OrgNode("child", "子", Some("root"))
        root.children.add(child)
        let nodes: Array<OrgNode> = [root, child]
        orgLayout(nodes, root, 100.0, 40.0, 80.0, true)
        @Assert(child.x > root.x)
    }

    /** 水平布局可绘制。 */
    @TestCase
    public func drawsHorizontal(): Unit {
        let json = """
{
  "type": "org-chart",
  "width": 800,
  "height": 400,
  "layout": "horizontal",
  "nodes": [
    { "id": "a", "name": "A" },
    { "id": "b", "name": "B", "parent": "a" }
  ]
}
"""
        @Assert(count(draw(json), "class=\"org-node\"") == 2)
    }

    /** 未知父节点。 */
    @TestCase
    public func rejectsMissingParent(): Unit {
        let json = """
{
  "type": "org-chart",
  "nodes": [
    { "id": "a", "name": "A", "parent": null },
    { "id": "b", "name": "B", "parent": "ghost" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法布局。 */
    @TestCase
    public func rejectsLayout(): Unit {
        let json = """
{
  "type": "org-chart",
  "layout": "radial",
  "nodes": [
    { "id": "a", "name": "A" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 节点宽度为零。 */
    @TestCase
    public func rejectsZeroWidth(): Unit {
        let json = """
{
  "type": "org-chart",
  "nodeWidth": 0,
  "nodes": [
    { "id": "a", "name": "A" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 环检测。 */
    @TestCase
    public func rejectsCycle(): Unit {
        let json = """
{
  "type": "org-chart",
  "nodes": [
    { "id": "a", "name": "A", "parent": "b" },
    { "id": "b", "name": "B", "parent": "a" }
  ]
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
  "type": "bar",
  "nodes": [
    { "id": "a", "name": "A" }
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
