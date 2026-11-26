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
public class WordNetworkChart_test {
    private func draw(json: String): String {
        WordNetworkChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "word-network",
  "title": "词语共现",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 100,
  "nodes": [
    { "id": "chart", "name": "图表", "weight": 40 },
    { "id": "svg", "name": "SVG", "weight": 30 },
    { "id": "json", "name": "JSON", "weight": 28 },
    { "id": "data", "name": "数据", "weight": 36 }
  ],
  "links": [
    { "source": "chart", "target": "svg", "value": 18 },
    { "source": "chart", "target": "json", "value": 15 },
    { "source": "chart", "target": "data", "value": 22 },
    { "source": "json", "target": "data", "value": 12 }
  ]
}
"""

    /** 四个节点、四个标签、四条连线。 */
    @TestCase
    public func drawsNetwork(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"word-network-node\"") == 4)
        @Assert(count(svg, "class=\"word-network-label\"") == 4)
        @Assert(count(svg, "class=\"word-network-link\"") == 4)
    }

    /** 半径映射边界。 */
    @TestCase
    public func mapsRadius(): Unit {
        @Assert(wordNetworkRadius(40.0, 40.0) == 18.0)
        @Assert(abs(wordNetworkRadius(10.0, 40.0) - (8.0 + 10.0 * 0.5)) < 1e-9)
    }

    /** 圆形布局首个节点在正上方。 */
    @TestCase
    public func computesRingPoint(): Unit {
        let point = wordNetworkRingPoint(100.0, 100.0, 50.0, 0, 4)
        @Assert(abs(point[0] - 100.0) < 1e-9)
        @Assert(abs(point[1] - 50.0) < 1e-9)
    }

    /** 圆形布局可渲染。 */
    @TestCase
    public func drawsCircularLayout(): Unit {
        let json = sample.replace("\"layout\": \"force\"", "\"layout\": \"circular\"")
        @Assert(count(draw(json), "class=\"word-network-node\"") == 4)
    }

    /** 非法布局。 */
    @TestCase
    public func rejectsInvalidLayout(): Unit {
        let json = sample.replace("\"layout\": \"force\"", "\"layout\": \"grid\"")
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 悬空连线。 */
    @TestCase
    public func rejectsDanglingLink(): Unit {
        let json = """
{
  "type": "word-network",
  "nodes": [ { "id": "a", "name": "甲" } ],
  "links": [ { "source": "a", "target": "b", "value": 1 } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 重复节点 id。 */
    @TestCase
    public func rejectsDuplicateId(): Unit {
        let json = """
{
  "type": "word-network",
  "nodes": [
    { "id": "a", "name": "甲" },
    { "id": "a", "name": "乙" }
  ],
  "links": [ { "source": "a", "target": "a", "value": 1 } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非正权重。 */
    @TestCase
    public func rejectsNonPositiveWeight(): Unit {
        let json = """
{
  "type": "word-network",
  "nodes": [ { "id": "a", "name": "甲", "weight": 0 } ],
  "links": []
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
  "type": "node-link",
  "nodes": [ { "id": "a", "name": "甲" } ],
  "links": []
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
