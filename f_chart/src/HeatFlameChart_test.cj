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
public class HeatFlameChart_test {
    private func draw(json: String): String {
        HeatFlameChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "heat-flame",
  "title": "CPU 热点",
  "width": 900,
  "height": 480,
  "heatField": "self",
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100, "self": 0 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40, "self": 5 },
    { "id": "render", "name": "render", "parent": "root", "value": 60, "self": 8 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25, "self": 25 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35, "self": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25, "self": 25 }
  ]
}
"""

    /** 六个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        @Assert(count(draw(sample), "class=\"heat-flame-node\"") == 6)
    }

    /** 节点标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("main"))
        @Assert(svg.contains("layout"))
    }

    /** 两端色与三色中点。 */
    @TestCase
    public func mapsColors(): Unit {
        let two = ["#ffffcc", "#800026"]
        @Assert(heatFlameColor(0.0, two) == "#ffffcc")
        @Assert(heatFlameColor(1.0, two) == "#800026")
        let three = ["#ffffcc", "#fd8d3c", "#800026"]
        @Assert(heatFlameColor(0.5, three) == "#fd8d3c")
    }

    /** 自定义热度字段。 */
    @TestCase
    public func supportsCustomHeatField(): Unit {
        let svg = draw("""
{
  "type": "heat-flame",
  "heatField": "cost",
  "colorRange": ["#ffffff", "#ff0000"],
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100, "cost": 0 },
    { "id": "a", "name": "a", "parent": "root", "value": 40, "cost": 10 }
  ]
}
""")
        @Assert(count(svg, "class=\"heat-flame-node\"") == 2)
    }

    /** 非数字热度。 */
    @TestCase
    public func rejectsNonNumericHeat(): Unit {
        try {
            draw("""
{
  "type": "heat-flame",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 10, "self": "a" } ]
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
  "type": "heat-flame",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 10 },
    { "id": "a", "name": "a", "parent": "missing", "value": 5 }
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
  "type": "heat-flame",
  "nodes": [
    { "id": "r1", "name": "a", "parent": null, "value": 10 },
    { "id": "r2", "name": "b", "parent": null, "value": 10 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空节点。 */
    @TestCase
    public func rejectsEmptyNodes(): Unit {
        try {
            draw("""
{
  "type": "heat-flame",
  "nodes": []
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
  "type": "flame",
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
