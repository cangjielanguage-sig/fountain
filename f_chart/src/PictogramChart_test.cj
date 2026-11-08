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
public class PictogramChart_test {
    private func draw(json: String): String {
        PictogramChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "pictogram",
  "title": "团队人数",
  "width": 720,
  "height": 360,
  "icon": "person",
  "unit": 10,
  "columns": 10,
  "series": [
    { "name": "研发", "data": [{ "name": "研发", "value": 120 }] },
    { "name": "市场", "data": [{ "name": "市场", "value": 60 }] }
  ]
}
"""

    /** 十八个图标。 */
    @TestCase
    public func drawsIcons(): Unit {
        @Assert(count(draw(sample), "class=\"pictogram-icon\"") == 18)
    }

    /** 两个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"pictogram-label\"") == 2)
        @Assert(svg.contains("研发"))
        @Assert(svg.contains("120"))
    }

    /** 图标数量向上取整。 */
    @TestCase
    public func computesCount(): Unit {
        @Assert(pictogramCount(120.0, 10.0) == 12)
        @Assert(pictogramCount(15.0, 10.0) == 2)
        @Assert(pictogramCount(0.0, 10.0) == 0)
        @Assert(pictogramCount(1.0, 10.0) == 1)
    }

    /** 圆形图标。 */
    @TestCase
    public func drawsCircleIcon(): Unit {
        let json = """
{
  "type": "pictogram",
  "icon": "circle",
  "unit": 5,
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 10 }] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"pictogram-icon\"") == 2)
    }

    /** 方形图标。 */
    @TestCase
    public func drawsSquareIcon(): Unit {
        let json = """
{
  "type": "pictogram",
  "icon": "square",
  "unit": 5,
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 10 }] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"pictogram-icon\"") == 2)
    }

    /** 自定义路径原样绘制。 */
    @TestCase
    public func drawsCustomPath(): Unit {
        let json = """
{
  "type": "pictogram",
  "icon": "M0 0 L10 0 L10 10 Z",
  "unit": 1,
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 2 }] }
  ]
}
"""
        let svg = draw(json)
        @Assert(svg.contains("M0 0 L10 0 L10 10 Z"))
        @Assert(count(svg, "class=\"pictogram-icon\"") == 2)
    }

    /** 单位为零。 */
    @TestCase
    public func rejectsZeroUnit(): Unit {
        let json = """
{
  "type": "pictogram",
  "unit": 0,
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 10 }] }
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

    /** 空图标。 */
    @TestCase
    public func rejectsEmptyIcon(): Unit {
        let json = """
{
  "type": "pictogram",
  "icon": "",
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 10 }] }
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

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "waffle",
  "series": [
    { "name": "A", "data": [{ "name": "A", "value": 10 }] }
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
