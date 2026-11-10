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
public class OfflineFlameChart_test {
    private func draw(json: String): String {
        OfflineFlameChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "offline-flame",
  "title": "render 子树",
  "width": 900,
  "height": 480,
  "root": "render",
  "maxDepth": 4,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 },
    { "id": "text", "name": "text", "parent": "layout", "value": 20 },
    { "id": "image", "name": "image", "parent": "layout", "value": 15 }
  ]
}
"""

    /** 指定子树只画 render 及其后代。 */
    @TestCase
    public func drawsSubtree(): Unit {
        @Assert(count(draw(sample), "class=\"offline-flame-node\"") == 5)
    }

    /** 缺省根绘制全树。 */
    @TestCase
    public func drawsAllByDefault(): Unit {
        let svg = draw("""
{
  "type": "offline-flame",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 },
    { "id": "text", "name": "text", "parent": "layout", "value": 20 },
    { "id": "image", "name": "image", "parent": "layout", "value": 15 }
  ]
}
""")
        @Assert(count(svg, "class=\"offline-flame-node\"") == 7)
    }

    /** 深度为零只画根。 */
    @TestCase
    public func limitsDepthToZero(): Unit {
        let svg = draw("""
{
  "type": "offline-flame",
  "maxDepth": 0,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "a", "name": "a", "parent": "root", "value": 50 }
  ]
}
""")
        @Assert(count(svg, "class=\"offline-flame-node\"") == 1)
    }

    /** 子树内深度为一。 */
    @TestCase
    public func limitsDepthToOne(): Unit {
        let svg = draw("""
{
  "type": "offline-flame",
  "root": "render",
  "maxDepth": 1,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 },
    { "id": "text", "name": "text", "parent": "layout", "value": 20 }
  ]
}
""")
        @Assert(count(svg, "class=\"offline-flame-node\"") == 3)
    }

    /** 未知 root。 */
    @TestCase
    public func rejectsUnknownRoot(): Unit {
        try {
            draw("""
{
  "type": "offline-flame",
  "root": "missing",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 100 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负 maxDepth。 */
    @TestCase
    public func rejectsNegativeMaxDepth(): Unit {
        try {
            draw("""
{
  "type": "offline-flame",
  "maxDepth": -1,
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 100 } ]
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
  "type": "offline-flame",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "a", "name": "a", "parent": "missing", "value": 10 }
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
  "type": "offline-flame",
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
  "type": "offline-flame",
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
