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
import fountain::f_svg.SvgParser

@Test
public class GanttChart_test {
    private func draw(json: String): String {
        GanttChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 两个任务 → 两条任务条 + 两个标签。 */
    @TestCase
    public func drawsTasks(): Unit {
        let svg = draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [
    { "id": "t1", "name": "需求", "start": "2026-01-01", "end": "2026-01-10" },
    { "id": "t2", "name": "开发", "start": "2026-01-08", "end": "2026-01-25" }
  ]
}
""")
        @Assert(count(svg, "class=\"gantt-bar\"") == 2)
        @Assert(count(svg, "class=\"task-label\"") == 2)
    }

    /** progress 叠加。 */
    @TestCase
    public func drawsProgress(): Unit {
        let svg = draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [
    { "id": "t1", "name": "开发", "start": "2026-01-01", "end": "2026-01-20", "progress": 0.5 }
  ]
}
""")
        @Assert(count(svg, "class=\"progress\"") == 1)
    }

    /** 依赖线。 */
    @TestCase
    public func drawsDependency(): Unit {
        let svg = draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [
    { "id": "t1", "name": "需求", "start": "2026-01-01", "end": "2026-01-10" },
    { "id": "t2", "name": "开发", "start": "2026-01-11", "end": "2026-01-25", "dependsOn": ["t1"] }
  ]
}
""")
        @Assert(count(svg, "class=\"dependency\"") == 1)
    }

    /** 日期刻度。 */
    @TestCase
    public func drawsDateAxis(): Unit {
        let svg = draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [{ "id": "t1", "name": "任务", "start": "2026-01-01", "end": "2026-02-15" }]
}
""")
        @Assert(svg.contains("2026-01") || svg.contains("2026-02"))
    }

    /** 悬空依赖。 */
    @TestCase
    public func rejectsDanglingDependency(): Unit {
        try {
            draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [
    { "id": "t1", "name": "开发", "start": "2026-01-01", "end": "2026-01-10", "dependsOn": ["missing"] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 tasks。 */
    @TestCase
    public func rejectsMissingTasks(): Unit {
        try {
            draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" }
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "timeline",
  "xAxis": { "type": "time" },
  "tasks": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 确定性。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [{ "id": "t1", "name": "任务", "start": "2026-01-01", "end": "2026-01-10" }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "gantt",
  "xAxis": { "type": "time" },
  "tasks": [{ "id": "t1", "name": "任务", "start": "2026-01-01", "end": "2026-01-10" }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}
