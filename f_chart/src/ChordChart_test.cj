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
public class ChordChart_test {
    private func draw(json: String): String {
        ChordChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "chord",
  "title": "城市迁移",
  "width": 640,
  "height": 640,
  "padAngle": 0.02,
  "nodes": [
    { "id": "bj", "name": "北京" },
    { "id": "sh", "name": "上海" },
    { "id": "gz", "name": "广州" },
    { "id": "sz", "name": "深圳" }
  ],
  "links": [
    { "source": "bj", "target": "sh", "value": 120 },
    { "source": "sh", "target": "bj", "value": 90 },
    { "source": "gz", "target": "sz", "value": 80 },
    { "source": "sz", "target": "gz", "value": 60 },
    { "source": "bj", "target": "sz", "value": 40 }
  ]
}
"""

    /** 四条外圈弧。 */
    @TestCase
    public func drawsArcs(): Unit {
        @Assert(count(draw(sample), "class=\"chord-arc\"") == 4)
    }

    /** 五条带状线。 */
    @TestCase
    public func drawsRibbons(): Unit {
        @Assert(count(draw(sample), "class=\"chord-ribbon\"") == 5)
    }

    /** 默认不显示标签。 */
    @TestCase
    public func hidesLabelsByDefault(): Unit {
        @Assert(count(draw(sample), "class=\"chord-label\"") == 0)
    }

    /** 显示标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw("""
{
  "type": "chord",
  "showLabels": true,
  "nodes": [
    { "id": "a", "name": "A" },
    { "id": "b", "name": "B" }
  ],
  "links": [ { "source": "a", "target": "b", "value": 1 } ]
}
""")
        @Assert(count(svg, "class=\"chord-label\"") == 2)
    }

    /** 弧路径格式。 */
    @TestCase
    public func buildsArcPath(): Unit {
        let path = chordArcPath(100.0, 100.0, 50.0, 0.0, 1.0)
        @Assert(path.startsWith("M "))
        @Assert(path.contains(" A "))
    }

    /** 带宽端点。 */
    @TestCase
    public func mapsWidth(): Unit {
        @Assert(abs(chordWidth(0.0, 100.0) - 1.0) < 1e-9)
        @Assert(abs(chordWidth(100.0, 100.0) - 7.0) < 1e-9)
    }

    /** 间隔过大。 */
    @TestCase
    public func rejectsLargePadAngle(): Unit {
        try {
            draw("""
{
  "type": "chord",
  "padAngle": 2,
  "nodes": [ { "id": "a" }, { "id": "b" }, { "id": "c" }, { "id": "d" } ],
  "links": [ { "source": "a", "target": "b", "value": 1 } ]
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
  "type": "chord",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "links": [ { "source": "a", "target": "missing", "value": 1 } ]
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
  "type": "chord",
  "nodes": [ { "id": "a" }, { "id": "b" } ],
  "links": [ { "source": "a", "target": "b", "value": 0 } ]
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
  "type": "chord",
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "a", "value": 1 } ]
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

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}
