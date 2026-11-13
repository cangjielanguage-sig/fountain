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
public class ArcChart_test {
    private func draw(json: String): String {
        ArcChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "arc",
  "title": "部门协作",
  "width": 640,
  "height": 640,
  "arcHeight": 0.5,
  "nodes": [
    { "id": "rd", "name": "研发" },
    { "id": "pm", "name": "产品" },
    { "id": "design", "name": "设计" },
    { "id": "qa", "name": "测试" },
    { "id": "ops", "name": "运维" }
  ],
  "links": [
    { "source": "pm", "target": "rd", "value": 8 },
    { "source": "design", "target": "rd", "value": 5 },
    { "source": "rd", "target": "qa", "value": 6 },
    { "source": "qa", "target": "ops", "value": 3 }
  ]
}
"""

    /** 五个节点与四条弧线。 */
    @TestCase
    public func drawsNodesAndArcs(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"arc-node\"") == 5)
        @Assert(count(svg, "class=\"arc-label\"") == 5)
        @Assert(count(svg, "class=\"arc-line\"") == 4)
    }

    /** 按总值降序排序下标。 */
    @TestCase
    public func sortsByValue(): Unit {
        let order = arcNodeOrder([3.0, 10.0, 5.0])
        @Assert(order[0] == 1)
        @Assert(order[1] == 2)
        @Assert(order[2] == 0)
    }

    /** sort 为 value 时正常绘制。 */
    @TestCase
    public func supportsValueSort(): Unit {
        let svg = draw("""
{
  "type": "arc",
  "sort": "value",
  "nodes": [
    { "id": "a", "name": "A" },
    { "id": "b", "name": "B" }
  ],
  "links": [ { "source": "a", "target": "b", "value": 2 } ]
}
""")
        @Assert(count(svg, "class=\"arc-line\"") == 1)
    }

    /** 非法 sort。 */
    @TestCase
    public func rejectsInvalidSort(): Unit {
        try {
            draw("""
{
  "type": "arc",
  "sort": "name",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "links": [ { "source": "a", "target": "b" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法弧高。 */
    @TestCase
    public func rejectsInvalidArcHeight(): Unit {
        try {
            draw("""
{
  "type": "arc",
  "arcHeight": 1.5,
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "links": [ { "source": "a", "target": "b" } ]
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
  "type": "arc",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "links": [ { "source": "a", "target": "missing" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 节点不足两个。 */
    @TestCase
    public func rejectsTooFewNodes(): Unit {
        try {
            draw("""
{
  "type": "arc",
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
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
  "type": "arc",
  "nodes": [ { "id": "a" }, { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
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
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}
