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
public class CartogramChart_test {
    private func draw(json: String): String {
        CartogramChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "cartogram",
  "title": "按人口变形",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "scaleBy": "sqrt",
  "regions": [
    { "id": "a", "name": "A 区", "value": 400, "path": "M 180 200 L 260 205 L 265 280 L 185 275 Z", "centroid": [220, 240] },
    { "id": "b", "name": "B 区", "value": 100, "path": "M 460 300 L 520 305 L 525 365 L 465 360 Z", "centroid": [490, 330] },
    { "id": "c", "name": "C 区", "value": 250, "path": "M 320 120 L 400 125 L 405 190 L 325 185 Z", "centroid": [360, 155] }
  ]
}
"""

    /** 三个变形区域。 */
    @TestCase
    public func drawsRegions(): Unit {
        @Assert(count(draw(sample), "class=\"cartogram-region\"") == 3)
    }

    /** 缺省质心时仍可绘制。 */
    @TestCase
    public func computesCentroidWhenMissing(): Unit {
        let svg = draw("""
{
  "type": "cartogram",
  "regions": [
    { "id": "a", "name": "A", "value": 10, "path": "M 0 0 L 20 0 L 20 20 L 0 20 Z" },
    { "id": "b", "name": "B", "value": 5, "path": "M 100 100 L 120 100 L 120 120 L 100 120 Z" }
  ]
}
""")
        @Assert(count(svg, "class=\"cartogram-region\"") == 2)
    }

    /** 缩放比例。 */
    @TestCase
    public func mapsScale(): Unit {
        @Assert(abs(cartogramScale(400.0, 400.0, "sqrt") - 1.0) < 1e-9)
        @Assert(abs(cartogramScale(100.0, 400.0, "sqrt") - 0.5) < 1e-9)
        @Assert(abs(cartogramScale(100.0, 400.0, "value") - 0.25) < 1e-9)
    }

    /** 非法 scaleBy。 */
    @TestCase
    public func rejectsInvalidScaleBy(): Unit {
        try {
            draw("""
{
  "type": "cartogram",
  "scaleBy": "log",
  "regions": [ { "id": "a", "name": "A", "value": 1, "path": "M 0 0 L 10 10 Z" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "cartogram",
  "regions": [ { "id": "a", "name": "A", "value": -1, "path": "M 0 0 L 10 10 Z" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法路径。 */
    @TestCase
    public func rejectsInvalidPath(): Unit {
        try {
            draw("""
{
  "type": "cartogram",
  "regions": [ { "id": "a", "name": "A", "value": 1, "path": "M Z" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法质心。 */
    @TestCase
    public func rejectsInvalidCentroid(): Unit {
        try {
            draw("""
{
  "type": "cartogram",
  "regions": [
    { "id": "a", "name": "A", "value": 1, "path": "M 0 0 L 10 10 Z", "centroid": [1] }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空区域。 */
    @TestCase
    public func rejectsEmptyRegions(): Unit {
        try {
            draw("""
{
  "type": "cartogram",
  "regions": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 regions。 */
    @TestCase
    public func rejectsMissingRegions(): Unit {
        try {
            draw("""
{ "type": "cartogram" }
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
  "type": "flow-map",
  "regions": []
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
