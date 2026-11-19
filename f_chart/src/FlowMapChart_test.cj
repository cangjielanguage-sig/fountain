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
public class FlowMapChart_test {
    private func draw(json: String): String {
        FlowMapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "flow-map",
  "title": "人口迁移",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "regions": [
    { "id": "a", "name": "A 市", "path": "M 170 200 L 250 210 L 245 280 L 165 270 Z" },
    { "id": "b", "name": "B 市", "path": "M 480 300 L 560 310 L 555 380 L 475 370 Z" }
  ],
  "flows": [
    { "source": "a", "target": "b", "value": 1200, "points": [[210, 240], [350, 300], [520, 340]] },
    { "source": "b", "target": "a", "value": 800, "points": [[520, 340], [350, 320], [210, 240]] }
  ]
}
"""

    /** 两条流向路径。 */
    @TestCase
    public func drawsFlows(): Unit {
        @Assert(count(draw(sample), "class=\"flow-map-path\"") == 2)
    }

    /** 两个底图区域。 */
    @TestCase
    public func drawsRegions(): Unit {
        @Assert(count(draw(sample), "class=\"flow-map-region\"") == 2)
    }

    /** 缺省 points 时按质心连线。 */
    @TestCase
    public func drawsWithoutPoints(): Unit {
        let svg = draw("""
{
  "type": "flow-map",
  "regions": [
    { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 L 0 20 Z" },
    { "id": "b", "name": "B", "path": "M 100 100 L 120 100 L 120 120 L 100 120 Z" }
  ],
  "flows": [ { "source": "a", "target": "b", "value": 10 } ]
}
""")
        @Assert(count(svg, "class=\"flow-map-path\"") == 1)
    }

    /** 线宽端点。 */
    @TestCase
    public func mapsWidth(): Unit {
        @Assert(abs(flowMapWidth(0.0, 100.0) - 1.0) < 1e-9)
        @Assert(abs(flowMapWidth(100.0, 100.0) - 5.0) < 1e-9)
    }

    /** 未知端点。 */
    @TestCase
    public func rejectsUnknownEndpoint(): Unit {
        try {
            draw("""
{
  "type": "flow-map",
  "regions": [ { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" } ],
  "flows": [ { "source": "a", "target": "missing", "value": 10 } ]
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
  "type": "flow-map",
  "regions": [
    { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" },
    { "id": "b", "name": "B", "path": "M 100 100 L 120 100 L 120 120 Z" }
  ],
  "flows": [ { "source": "a", "target": "b", "value": 0 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法坐标对。 */
    @TestCase
    public func rejectsInvalidPointPair(): Unit {
        try {
            draw("""
{
  "type": "flow-map",
  "regions": [ { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" } ],
  "flows": [ { "source": "a", "target": "a", "value": 1, "points": [[1]] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 重复区域 id。 */
    @TestCase
    public func rejectsDuplicateRegion(): Unit {
        try {
            draw("""
{
  "type": "flow-map",
  "regions": [
    { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" },
    { "id": "a", "name": "B", "path": "M 100 100 L 120 100 L 120 120 Z" }
  ],
  "flows": [ { "source": "a", "target": "a", "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空流向。 */
    @TestCase
    public func rejectsEmptyFlows(): Unit {
        try {
            draw("""
{
  "type": "flow-map",
  "regions": [ { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" } ],
  "flows": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 flows。 */
    @TestCase
    public func rejectsMissingFlows(): Unit {
        try {
            draw("""
{
  "type": "flow-map",
  "regions": [ { "id": "a", "name": "A", "path": "M 0 0 L 20 0 L 20 20 Z" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "heat-map",
  "regions": [],
  "flows": []
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
