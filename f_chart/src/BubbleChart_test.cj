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
public class BubbleChart_test {
    private func draw(json: String): String {
        BubbleChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "bubble",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    {
      "name": "国家",
      "sizeRange": [6, 34],
      "data": [
        { "x": 12000, "y": 72, "size": 40, "label": "A 国" },
        { "x": 25000, "y": 78, "size": 80, "label": "B 国" },
        { "x": 40000, "y": 82, "size": 120, "label": "C 国" },
        { "x": 60000, "y": 84, "size": 60, "label": "D 国" }
      ]
    }
  ]
}
"""

    /** 四个气泡与四个标签。 */
    @TestCase
    public func drawsBubbles(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"bubble\"") == 4)
        @Assert(count(svg, "class=\"bubble-label\"") == 4)
    }

    /** 半径线性映射。 */
    @TestCase
    public func mapsRadius(): Unit {
        @Assert(bubbleRadius(40.0, 40.0, 120.0, 6.0, 34.0) == 6.0)
        @Assert(bubbleRadius(120.0, 40.0, 120.0, 6.0, 34.0) == 34.0)
        @Assert(bubbleRadius(80.0, 40.0, 120.0, 6.0, 34.0) == 20.0)
        @Assert(bubbleRadius(50.0, 50.0, 50.0, 6.0, 34.0) == 20.0)
    }

    /** 非法 sizeRange。 */
    @TestCase
    public func rejectsInvalidSizeRange(): Unit {
        try {
            draw("""
{
  "type": "bubble",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "甲", "sizeRange": [20, 10], "data": [{ "x": 1, "y": 1, "size": 5 }] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺少 size。 */
    @TestCase
    public func rejectsMissingSize(): Unit {
        try {
            draw("""
{
  "type": "bubble",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [{ "x": 1, "y": 1 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 非数值 x。 */
    @TestCase
    public func rejectsNonNumericX(): Unit {
        try {
            draw("""
{
  "type": "bubble",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [{ "x": "1", "y": 1, "size": 5 }] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{ "type": "bubble" }
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
  "type": "scatter",
  "xAxis": { "type": "linear" },
  "yAxis": { "type": "linear" },
  "series": [{ "name": "甲", "data": [{ "x": 1, "y": 1, "size": 5 }] }]
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
