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
public class CirclePackingChart_test {
    private func draw(json: String): String {
        CirclePackingChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "circle-packing",
  "title": "文件类型占比",
  "width": 640,
  "height": 640,
  "padding": 2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "code", "name": "代码", "parent": "root" },
    { "id": "asset", "name": "资源", "parent": "root" },
    { "id": "ts", "name": "TypeScript", "parent": "code", "value": 120 },
    { "id": "cj", "name": "Cangjie", "parent": "code", "value": 90 },
    { "id": "img", "name": "图片", "parent": "asset", "value": 70 },
    { "id": "font", "name": "字体", "parent": "asset", "value": 30 }
  ]
}
"""

    /** 七个圆。 */
    @TestCase
    public func drawsCircles(): Unit {
        @Assert(count(draw(sample), "class=\"circle-packing-circle\"") == 7)
    }

    /** 大圆带标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"circle-packing-label\"") > 0)
        @Assert(svg.contains("全部"))
    }

    /** 面积半径。 */
    @TestCase
    public func computesRadius(): Unit {
        @Assert(abs(circlePackingRadius(100.0, 2.0) - 20.0) < 1e-9)
        @Assert(abs(circlePackingRadius(25.0, 2.0) - 10.0) < 1e-9)
    }

    /** 负间距。 */
    @TestCase
    public func rejectsNegativePadding(): Unit {
        try {
            draw("""
{
  "type": "circle-packing",
  "padding": -1,
  "nodes": [ { "id": "root", "name": "根", "parent": null, "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 未知父节点。 */
    @TestCase
    public func rejectsUnknownParent(): Unit {
        try {
            draw("""
{
  "type": "circle-packing",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "A", "parent": "missing", "value": 1 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 多个根节点。 */
    @TestCase
    public func rejectsMultipleRoots(): Unit {
        try {
            draw("""
{
  "type": "circle-packing",
  "nodes": [
    { "id": "r1", "name": "A", "parent": null, "value": 1 },
    { "id": "r2", "name": "B", "parent": null, "value": 2 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 叶子缺值。 */
    @TestCase
    public func rejectsLeafWithoutValue(): Unit {
        try {
            draw("""
{
  "type": "circle-packing",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "A", "parent": "root" }
  ]
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
  "type": "sunburst",
  "nodes": []
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
