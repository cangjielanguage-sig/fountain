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
public class DifferentialFlameChart_test {
    private func draw(json: String): String {
        DifferentialFlameChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "differential-flame",
  "title": "版本差异",
  "width": 900,
  "height": 480,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value1": 100, "value2": 120 },
    { "id": "parse", "name": "parse", "parent": "root", "value1": 40, "value2": 30 },
    { "id": "render", "name": "render", "parent": "root", "value1": 60, "value2": 90 },
    { "id": "lex", "name": "lex", "parent": "parse", "value1": 25, "value2": 20 },
    { "id": "layout", "name": "layout", "parent": "render", "value1": 35, "value2": 55 },
    { "id": "paint", "name": "paint", "parent": "render", "value1": 25, "value2": 35 }
  ]
}
"""

    /** 六个节点。 */
    @TestCase
    public func drawsNodes(): Unit {
        @Assert(count(draw(sample), "class=\"diff-flame-node\"") == 6)
    }

    /** 节点标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("main"))
        @Assert(svg.contains("render"))
    }

    /** 增加、减少与无变化。 */
    @TestCase
    public func mapsColors(): Unit {
        let colors = ["#4a90d9", "#e53935"]
        @Assert(differentialColor(10.0, 10.0, colors) == "#e53935")
        @Assert(differentialColor(-10.0, 10.0, colors) == "#4a90d9")
        @Assert(differentialColor(0.0, 10.0, colors) == "#f0f0f0")
    }

    /** 三色范围的中性色。 */
    @TestCase
    public func honorsTripleColorRange(): Unit {
        let colors = ["#0000ff", "#ffffff", "#ff0000"]
        @Assert(differentialColor(0.0, 10.0, colors) == "#ffffff")
        @Assert(differentialColor(10.0, 10.0, colors) == "#ff0000")
    }

    /** 缺少 value2。 */
    @TestCase
    public func rejectsMissingValue2(): Unit {
        try {
            draw("""
{
  "type": "differential-flame",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value1": 10 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "differential-flame",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value1": -1, "value2": 10 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 子节点和超过父节点。 */
    @TestCase
    public func rejectsOversizedChildren(): Unit {
        try {
            draw("""
{
  "type": "differential-flame",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value1": 100, "value2": 100 },
    { "id": "a", "name": "a", "parent": "root", "value1": 10, "value2": 150 }
  ]
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
  "type": "differential-flame",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value1": 10, "value2": 10 },
    { "id": "a", "name": "a", "parent": "missing", "value1": 5, "value2": 5 }
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
  "type": "differential-flame",
  "nodes": [
    { "id": "r1", "name": "a", "parent": null, "value1": 10, "value2": 10 },
    { "id": "r2", "name": "b", "parent": null, "value1": 10, "value2": 10 }
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
  "type": "differential-flame",
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
