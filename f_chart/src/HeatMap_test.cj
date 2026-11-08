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
public class HeatMapChart_test {
    private func draw(json: String): String {
        HeatMapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "heat-map",
  "title": "访问热力",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 28,
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 240, "y": 220, "value": 20 },
    { "x": 300, "y": 260, "value": 45 },
    { "x": 420, "y": 310, "value": 80 },
    { "x": 500, "y": 360, "value": 35 }
  ]
}
"""

    /** 四个热力点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"heat-map-point\"") == 4)
    }

    /** 一个底图区域。 */
    @TestCase
    public func drawsRegion(): Unit {
        @Assert(count(draw(sample), "class=\"heat-map-region\"") == 1)
    }

    /** 默认半径为 24。 */
    @TestCase
    public func usesDefaultRadius(): Unit {
        let svg = draw("""
{
  "type": "heat-map",
  "points": [ { "x": 10, "y": 10, "value": 1 } ]
}
""")
        @Assert(svg.contains("r=\"24"))
    }

    /** 最值取首末色。 */
    @TestCase
    public func usesColorRange(): Unit {
        let svg = draw("""
{
  "type": "heat-map",
  "colorRange": ["#ffffcc", "#800026"],
  "points": [
    { "x": 10, "y": 10, "value": 0 },
    { "x": 20, "y": 20, "value": 10 }
  ]
}
""")
        @Assert(svg.contains("#ffffcc"))
        @Assert(svg.contains("#800026"))
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "heat-map",
  "points": [ { "x": 10, "y": 10, "value": -1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非正半径。 */
    @TestCase
    public func rejectsNonPositiveRadius(): Unit {
        try {
            draw("""
{
  "type": "heat-map",
  "radius": 0,
  "points": [ { "x": 10, "y": 10, "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字坐标。 */
    @TestCase
    public func rejectsNonNumericPoint(): Unit {
        try {
            draw("""
{
  "type": "heat-map",
  "points": [ { "x": "a", "y": 10, "value": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空点集。 */
    @TestCase
    public func rejectsEmptyPoints(): Unit {
        try {
            draw("""
{
  "type": "heat-map",
  "points": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 points。 */
    @TestCase
    public func rejectsMissingPoints(): Unit {
        try {
            draw("""
{ "type": "heat-map" }
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
  "type": "dot-density-map",
  "points": []
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
