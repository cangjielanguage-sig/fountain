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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class DotDensityMapChart_test {
    private func draw(json: String): String {
        DotDensityMapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "dot-density-map",
  "title": "门店分布",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 3,
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 220, "y": 210, "weight": 2 },
    { "x": 260, "y": 230, "weight": 1 },
    { "x": 410, "y": 300, "weight": 3 },
    { "x": 450, "y": 320, "weight": 2 },
    { "x": 520, "y": 380, "weight": 1 }
  ]
}
"""

    /** 五个点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"dot-density-point\"") == 5)
    }

    /** 一个底图区域。 */
    @TestCase
    public func drawsRegion(): Unit {
        @Assert(count(draw(sample), "class=\"dot-density-region\"") == 1)
    }

    /** 无底图仍画点。 */
    @TestCase
    public func drawsWithoutRegions(): Unit {
        let svg = draw("""
{
  "type": "dot-density-map",
  "points": [ { "x": 10, "y": 20 }, { "x": 30, "y": 40 } ]
}
""")
        @Assert(count(svg, "class=\"dot-density-point\"") == 2)
        @Assert(count(svg, "class=\"dot-density-region\"") == 0)
    }

    /** 权重平方根半径。 */
    @TestCase
    public func scalesRadius(): Unit {
        @Assert(abs(dotDensityRadius(1.0, 3.0) - 3.0) < 1e-9)
        @Assert(abs(dotDensityRadius(4.0, 3.0) - 6.0) < 1e-9)
    }

    /** 非正半径。 */
    @TestCase
    public func rejectsNonPositiveRadius(): Unit {
        try {
            draw("""
{
  "type": "dot-density-map",
  "radius": 0,
  "points": [ { "x": 1, "y": 1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负权重。 */
    @TestCase
    public func rejectsNegativeWeight(): Unit {
        try {
            draw("""
{
  "type": "dot-density-map",
  "points": [ { "x": 1, "y": 1, "weight": -1 } ]
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
  "type": "dot-density-map",
  "points": [ { "x": "a", "y": 1 } ]
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
  "type": "dot-density-map",
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
{ "type": "dot-density-map" }
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
  "type": "choropleth",
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
