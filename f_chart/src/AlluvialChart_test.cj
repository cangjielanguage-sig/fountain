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
public class AlluvialChart_test {
    private func draw(json: String): String {
        AlluvialChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "alluvial",
  "title": "用户状态迁移",
  "width": 800,
  "height": 480,
  "stages": ["2025", "2026"],
  "nodeWidth": 14,
  "nodeGap": 10,
  "nodes": [
    { "id": "new-2025", "name": "新客", "stage": "2025" },
    { "id": "old-2025", "name": "老客", "stage": "2025" },
    { "id": "new-2026", "name": "新客", "stage": "2026" },
    { "id": "old-2026", "name": "老客", "stage": "2026" },
    { "id": "lost-2026", "name": "流失", "stage": "2026" }
  ],
  "links": [
    { "source": "new-2025", "target": "old-2026", "value": 420 },
    { "source": "new-2025", "target": "lost-2026", "value": 180 },
    { "source": "old-2025", "target": "old-2026", "value": 600 },
    { "source": "old-2025", "target": "lost-2026", "value": 120 },
    { "source": "new-2026", "target": "old-2026", "value": 300 }
  ]
}
"""

    /** 五个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        @Assert(count(draw(sample), "class=\"alluvial-node\"") == 5)
    }

    /** 五条流量带。 */
    @TestCase
    public func drawsLinks(): Unit {
        @Assert(count(draw(sample), "class=\"alluvial-link\"") == 5)
    }

    /** 五个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        @Assert(count(draw(sample), "class=\"alluvial-label\"") == 5)
    }

    /** 列内高度均分。 */
    @TestCase
    public func allocatesHeights(): Unit {
        let heights = alluvialHeights([1.0, 1.0], 100.0, 10.0)
        @Assert(heights.size == 2)
        @Assert(abs(heights[0] - 45.0) < 1e-9)
        @Assert(abs(heights[1] - 45.0) < 1e-9)
    }

    /** 未知阶段。 */
    @TestCase
    public func rejectsUnknownStage(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "stages": ["2025"],
  "nodes": [ { "id": "a", "stage": "2024" } ],
  "links": [ { "source": "a", "target": "a", "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非正流量。 */
    @TestCase
    public func rejectsNonPositiveValue(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "stages": ["2025"],
  "nodes": [ { "id": "a", "stage": "2025" } ],
  "links": [ { "source": "a", "target": "a", "value": 0 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非正节点宽。 */
    @TestCase
    public func rejectsInvalidNodeWidth(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "stages": ["2025"],
  "nodeWidth": 0,
  "nodes": [ { "id": "a", "stage": "2025" } ],
  "links": [ { "source": "a", "target": "a", "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负节点间距。 */
    @TestCase
    public func rejectsNegativeNodeGap(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "stages": ["2025"],
  "nodeGap": -1,
  "nodes": [ { "id": "a", "stage": "2025" } ],
  "links": [ { "source": "a", "target": "a", "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 stages。 */
    @TestCase
    public func rejectsMissingStages(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "nodes": [],
  "links": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 空节点。 */
    @TestCase
    public func rejectsEmptyNodes(): Unit {
        try {
            draw("""
{
  "type": "alluvial",
  "stages": ["2025"],
  "nodes": [],
  "links": []
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
  "type": "hive",
  "stages": [],
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
