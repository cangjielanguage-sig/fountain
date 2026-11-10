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
public class IcicleChart_test {
    private func draw(json: String): String {
        IcicleChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "icicle",
  "title": "调用栈冰柱图",
  "width": 900,
  "height": 480,
  "orientation": "top-down",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
"""

    /** 七个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        @Assert(count(draw(sample), "class=\"icicle-node\"") == 7)
    }

    /** 节点标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("main"))
        @Assert(svg.contains("layout"))
    }

    /** 支持自底向上。 */
    @TestCase
    public func supportsBottomUp(): Unit {
        let svg = draw("""
{
  "type": "icicle",
  "orientation": "bottom-up",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 10 },
    { "id": "a", "name": "a", "parent": "root", "value": 10 }
  ]
}
""")
        @Assert(count(svg, "class=\"icicle-node\"") == 2)
    }

    /** 未知父节点。 */
    @TestCase
    public func rejectsUnknownParent(): Unit {
        try {
            draw("""
{
  "type": "icicle",
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
  "type": "icicle",
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

    /** 非正节点值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "icicle",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 0 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 子节点值之和超过父节点。 */
    @TestCase
    public func rejectsOversizedChildren(): Unit {
        try {
            draw("""
{
  "type": "icicle",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 50 },
    { "id": "a", "name": "a", "parent": "root", "value": 60 }
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
  "type": "icicle",
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
