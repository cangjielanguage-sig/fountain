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
package fountain::f_chart.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_chart.*
import fountain::f_data.json.*

@Test
public class TuiFlameChart_test {
    private func draw(json: String): String {
        TuiFlameChart().draw(JsonValue.fromStr(json).asObject())
    }

    private func lineOf(text: String, needle: String): Int64 {
        let lines = text.split("\n")
        for (index in 0..lines.size) {
            if (lines[index].contains(needle)) {
                return index
            }
        }
        -1
    }

    private let sample: String = """
{
  "type": "flame",
  "title": "CPU 火焰图",
  "width": 80,
  "height": 24,
  "orientation": "bottom-up",
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

    /** 标题、标签与真彩色块。 */
    @TestCase
    public func drawsFlameGraph(): Unit {
        let svg = draw(sample)
        let plain = tuiStripAnsi(svg)
        @Assert(svg.contains("\u{1B}[38;2;"))
        @Assert(svg.contains("\u{1B}[0m\n"))
        @Assert(plain.contains("CPU 火焰图"))
        @Assert(plain.contains("main"))
        @Assert(plain.contains("parse"))
        @Assert(plain.contains("render"))
        @Assert(plain.contains("█"))
        @Assert(plain.split("\n").size == 25)
    }

    /** 同名节点颜色稳定，不同名称通常不同色。 */
    @TestCase
    public func usesStableNameColors(): Unit {
        let first = draw(sample)
        let second = draw(sample)
        @Assert(first == second)
        @Assert(first.contains("\u{1B}[38;2;"))
    }

    /** colorBy=value 使用热力色阶。 */
    @TestCase
    public func usesHeatColors(): Unit {
        let json = """
{
  "type": "flame",
  "width": 60,
  "height": 16,
  "colorBy": "value",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "a", "name": "a", "parent": "root", "value": 60 }
  ]
}
"""
        let svg = draw(json)
        @Assert(svg.contains("\u{1B}[38;2;8;48;107m"))
        @Assert(svg.contains("\u{1B}[38;2;33;113;181m"))
    }

    /** bottom-up：根在子节点下方。 */
    @TestCase
    public func supportsBottomUp(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(lineOf(plain, "main") > lineOf(plain, "parse"))
        @Assert(lineOf(plain, "parse") > lineOf(plain, "lex"))
    }

    /** top-down：根在子节点上方。 */
    @TestCase
    public func supportsTopDown(): Unit {
        let json = """
{
  "type": "flame",
  "width": 60,
  "height": 16,
  "orientation": "top-down",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "a", "name": "child", "parent": "root", "value": 100 }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(lineOf(plain, "main") < lineOf(plain, "child"))
    }

    /** 自定义尺寸与层高。 */
    @TestCase
    public func respectsSizeAndFrameHeight(): Unit {
        let json = """
{
  "type": "flame",
  "width": 50,
  "height": 14,
  "frameHeight": 2,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 10 },
    { "id": "a", "name": "a", "parent": "root", "value": 5 }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.split("\n").size == 15)
    }

    /** 层级超出可用高度。 */
    @TestCase
    public func rejectsTooManyLevels(): Unit {
        try {
            draw("""
{
  "type": "flame",
  "width": 20,
  "height": 8,
  "nodes": [
    { "id": "n0", "name": "n0", "parent": null, "value": 10 },
    { "id": "n1", "name": "n1", "parent": "n0", "value": 9 },
    { "id": "n2", "name": "n2", "parent": "n1", "value": 8 },
    { "id": "n3", "name": "n3", "parent": "n2", "value": 7 },
    { "id": "n4", "name": "n4", "parent": "n3", "value": 6 },
    { "id": "n5", "name": "n5", "parent": "n4", "value": 5 },
    { "id": "n6", "name": "n6", "parent": "n5", "value": 4 }
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
  "type": "flame",
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
  "type": "flame",
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

    /** 重复 id。 */
    @TestCase
    public func rejectsDuplicateIds(): Unit {
        try {
            draw("""
{
  "type": "flame",
  "nodes": [
    { "id": "root", "name": "a", "parent": null, "value": 10 },
    { "id": "root", "name": "b", "parent": "root", "value": 5 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 子节点之和超过父节点。 */
    @TestCase
    public func rejectsOversizedChildren(): Unit {
        try {
            draw("""
{
  "type": "flame",
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

    /** 非正节点值。 */
    @TestCase
    public func rejectsNonPositiveValue(): Unit {
        try {
            draw("""
{
  "type": "flame",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 0 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法方向。 */
    @TestCase
    public func rejectsInvalidOrientation(): Unit {
        try {
            draw("""
{
  "type": "flame",
  "orientation": "sideways",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 colorBy。 */
    @TestCase
    public func rejectsInvalidColorBy(): Unit {
        try {
            draw("""
{
  "type": "flame",
  "colorBy": "depth",
  "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 1 } ]
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
{ "type": "icicle", "nodes": [ { "id": "root", "name": "main", "parent": null, "value": 1 } ] }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
