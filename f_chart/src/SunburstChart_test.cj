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
public class SunburstChart_test {
    private func draw(json: String): String {
        SunburstChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "sunburst",
  "title": "产品收入层级",
  "width": 640,
  "height": 640,
  "innerRadius": 0.2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "hw", "name": "硬件", "parent": "root" },
    { "id": "sw", "name": "软件", "parent": "root" },
    { "id": "phone", "name": "手机", "parent": "hw", "value": 60 },
    { "id": "pc", "name": "电脑", "parent": "hw", "value": 40 },
    { "id": "saas", "name": "SaaS", "parent": "sw", "value": 55 },
    { "id": "license", "name": "授权", "parent": "sw", "value": 25 }
  ]
}
"""

    /** 六个扇环（根节点不画）。 */
    @TestCase
    public func drawsArcs(): Unit {
        @Assert(count(draw(sample), "class=\"sunburst-arc\"") == 6)
    }

    /** 两个一级标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        @Assert(count(draw(sample), "class=\"sunburst-label\"") == 2)
    }

    /** 扇环路径含两段弧并闭合。 */
    @TestCase
    public func buildsArcPath(): Unit {
        let path = sunburstArcPath(100.0, 100.0, 20.0, 60.0, 0.0, 1.0)
        @Assert(path.startsWith("M "))
        @Assert(path.contains(" A "))
        @Assert(path.endsWith("Z"))
    }

    /** 非法内半径。 */
    @TestCase
    public func rejectsInvalidInnerRadius(): Unit {
        try {
            draw("""
{
  "type": "sunburst",
  "innerRadius": 1,
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
  "type": "sunburst",
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
  "type": "sunburst",
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
  "type": "sunburst",
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

    /** 非法 sort。 */
    @TestCase
    public func rejectsInvalidSort(): Unit {
        try {
            draw("""
{
  "type": "sunburst",
  "sort": "name",
  "nodes": [ { "id": "root", "name": "根", "parent": null, "value": 1 } ]
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
  "type": "circle-packing",
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
