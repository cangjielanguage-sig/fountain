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
public class TimelineChart_test {
    private func draw(json: String): String {
        TimelineChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "timeline",
  "title": "产品里程碑",
  "width": 900,
  "height": 420,
  "orientation": "horizontal",
  "events": [
    { "date": "2026-01", "title": "立项", "description": "完成需求评审" },
    { "date": "2026-03", "title": "内测", "description": "首批用户试用" },
    { "date": "2026-06", "title": "公测", "description": "开放注册" },
    { "date": "2026-09", "title": "正式发布", "description": "全量上线" }
  ]
}
"""

    /** 四个事件点与轴线。 */
    @TestCase
    public func drawsEvents(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"timeline-dot\"") == 4)
        @Assert(count(svg, "class=\"timeline-axis\"") == 1)
    }

    /** 时间、标题与描述。 */
    @TestCase
    public func drawsTexts(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"timeline-date\"") == 4)
        @Assert(count(svg, "class=\"timeline-title\"") == 4)
        @Assert(count(svg, "class=\"timeline-desc\"") == 4)
        @Assert(svg.contains("立项"))
        @Assert(svg.contains("完成需求评审"))
    }

    /** 垂直布局。 */
    @TestCase
    public func drawsVertical(): Unit {
        let json = """
{
  "type": "timeline",
  "width": 480,
  "height": 620,
  "orientation": "vertical",
  "events": [
    { "date": "2026-01", "title": "立项" },
    { "date": "2026-03", "title": "内测" }
  ]
}
"""
        let svg = draw(json)
        @Assert(count(svg, "class=\"timeline-dot\"") == 2)
        @Assert(count(svg, "class=\"timeline-desc\"") == 0)
    }

    /** 非法方向。 */
    @TestCase
    public func rejectsOrientation(): Unit {
        let json = """
{
  "type": "timeline",
  "orientation": "diagonal",
  "events": [
    { "date": "2026-01", "title": "立项" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺少标题。 */
    @TestCase
    public func rejectsMissingTitle(): Unit {
        let json = """
{
  "type": "timeline",
  "events": [
    { "date": "2026-01" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 空事件。 */
    @TestCase
    public func rejectsEmptyEvents(): Unit {
        let json = """
{
  "type": "timeline",
  "events": []
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "gantt",
  "events": [
    { "date": "2026-01", "title": "立项" }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
