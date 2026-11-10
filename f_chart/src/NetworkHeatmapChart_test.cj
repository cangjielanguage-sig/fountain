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
public class NetworkHeatmapChart_test {
    private func draw(json: String): String {
        NetworkHeatmapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "network-heatmap",
  "title": "节点关系强度",
  "width": 640,
  "height": 640,
  "nodes": [
    { "id": "a", "name": "网关" },
    { "id": "b", "name": "订单" },
    { "id": "c", "name": "库存" },
    { "id": "d", "name": "支付" }
  ],
  "colorRange": ["#f7fbff", "#6baed6", "#08306b"],
  "series": [
    {
      "name": "调用量",
      "data": [
        [0, 120, 80, 95],
        [60, 0, 40, 130],
        [35, 25, 0, 20],
        [90, 110, 15, 0]
      ]
    }
  ]
}
"""

    /** 4×4 共 16 个单元格。 */
    @TestCase
    public func drawsCells(): Unit {
        @Assert(count(draw(sample), "class=\"network-heatmap-cell\"") == 16)
    }

    /** 节点名作为行列标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("网关"))
        @Assert(svg.contains("支付"))
    }

    /** showValues 为 true 时输出 16 个数值。 */
    @TestCase
    public func drawsValues(): Unit {
        let svg = draw("""
{
  "type": "network-heatmap",
  "showValues": true,
  "nodes": [
    { "id": "a", "name": "A" },
    { "id": "b", "name": "B" }
  ],
  "series": [ { "name": "值", "data": [ [1, 2], [3, 4] ] } ]
}
""")
        @Assert(count(svg, "class=\"network-heatmap-value\"") == 4)
    }

    /** 默认不显示数值。 */
    @TestCase
    public func hidesValuesByDefault(): Unit {
        @Assert(count(draw(sample), "class=\"network-heatmap-value\"") == 0)
    }

    /** 非方阵。 */
    @TestCase
    public func rejectsRaggedMatrix(): Unit {
        try {
            draw("""
{
  "type": "network-heatmap",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "series": [ { "name": "值", "data": [ [1, 2], [3] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 阶数与节点数不符。 */
    @TestCase
    public func rejectsOrderMismatch(): Unit {
        try {
            draw("""
{
  "type": "network-heatmap",
  "nodes": [ { "id": "a" }, { "id": "b" }, { "id": "c" }, { "id": "d" } ],
  "series": [ { "name": "值", "data": [ [1, 2, 3], [4, 5, 6], [7, 8, 9] ] } ]
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
  "type": "network-heatmap",
  "nodes": [ { "id": "a" }, { "id": "a" } ],
  "series": [ { "name": "值", "data": [ [1, 2], [3, 4] ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字元素。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "network-heatmap",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "series": [ { "name": "值", "data": [ [1, "x"], [3, 4] ] } ]
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
  "type": "heatmap",
  "nodes": [],
  "series": []
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
