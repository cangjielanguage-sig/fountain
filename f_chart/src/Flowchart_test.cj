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
import fountain::f_svg.SvgParser

@Test
public class Flowchart_test {
    private func draw(json: String): String {
        Flowchart().draw(JsonValue.fromStr(json).asObject())
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

    /** 四节点、三边。 */
    @TestCase
    public func drawsNodesAndEdges(): Unit {
        let svg = draw("""
{
  "type": "flowchart",
  "nodes": [
    { "id": "a", "label": "开始", "shape": "ellipse" },
    { "id": "b", "label": "处理", "shape": "rect" },
    { "id": "c", "label": "判断", "shape": "diamond" },
    { "id": "d", "label": "结束", "shape": "ellipse" }
  ],
  "edges": [
    { "source": "a", "target": "b" },
    { "source": "b", "target": "c" },
    { "source": "c", "target": "d", "label": "是" }
  ]
}
""")
        @Assert(count(svg, "class=\"node\"") == 3)
        @Assert(count(svg, "class=\"node node-diamond\"") == 1)
        @Assert(count(svg, "class=\"edge\"") == 3)
    }

    /** 菱形节点 class。 */
    @TestCase
    public func drawsDiamondNode(): Unit {
        let svg = draw("""
{
  "type": "flowchart",
  "nodes": [
    { "id": "a", "label": "开始" },
    { "id": "b", "label": "判断", "shape": "diamond" }
  ],
  "edges": [{ "source": "a", "target": "b" }]
}
""")
        @Assert(count(svg, "class=\"node node-diamond\"") == 1)
    }

    /** 标签与边标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw("""
{
  "type": "flowchart",
  "nodes": [
    { "id": "a", "label": "开始" },
    { "id": "b", "label": "结束" }
  ],
  "edges": [{ "source": "a", "target": "b", "label": "下一步" }]
}
""")
        @Assert(svg.contains("开始"))
        @Assert(svg.contains("结束"))
        @Assert(svg.contains("下一步"))
    }

    /** manual 布局使用 x/y。 */
    @TestCase
    public func supportsManualLayout(): Unit {
        let svg = draw("""
{
  "type": "flowchart",
  "layout": "manual",
  "nodes": [
    { "id": "a", "label": "A", "x": 40, "y": 80 },
    { "id": "b", "label": "B", "x": 300, "y": 80 }
  ],
  "edges": [{ "source": "a", "target": "b" }]
}
""")
        @Assert(svg.contains("x=\"40px\""))
        @Assert(svg.contains("x=\"300px\""))
    }

    /** 悬空边。 */
    @TestCase
    public func rejectsDanglingEdge(): Unit {
        try {
            draw("""
{
  "type": "flowchart",
  "nodes": [{ "id": "a", "label": "A" }],
  "edges": [{ "source": "a", "target": "missing" }]
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
{
  "type": "flowchart",
  "edges": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "sequence",
  "nodes": [{ "id": "a", "label": "A" }],
  "edges": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 确定性。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "flowchart",
  "nodes": [{ "id": "a", "label": "A" }, { "id": "b", "label": "B" }],
  "edges": [{ "source": "a", "target": "b" }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "flowchart",
  "nodes": [{ "id": "a", "label": "A" }],
  "edges": []
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
