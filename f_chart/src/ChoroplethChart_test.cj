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
public class ChoroplethChart_test {
    private func draw(json: String): String {
        ChoroplethChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "choropleth",
  "title": "各省销售额",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showLabels": true,
  "regions": [
    { "id": "east", "name": "华东", "value": 320, "path": "M 420 180 L 560 190 L 570 300 L 430 310 Z" },
    { "id": "south", "name": "华南", "value": 260, "path": "M 430 320 L 560 315 L 550 430 L 420 420 Z" },
    { "id": "north", "name": "华北", "value": 210, "path": "M 300 120 L 410 130 L 415 240 L 300 230 Z" },
    { "id": "west", "name": "西部", "value": 150, "path": "M 120 180 L 290 190 L 295 360 L 130 350 Z" }
  ]
}
"""

    /** 四个区域。 */
    @TestCase
    public func drawsRegions(): Unit {
        @Assert(count(draw(sample), "class=\"choropleth-region\"") == 4)
    }

    /** viewBox 属性。 */
    @TestCase
    public func writesViewBox(): Unit {
        @Assert(draw(sample).contains("viewBox=\"0 0 760 560\""))
    }

    /** 显示区域标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"choropleth-label\"") == 4)
        @Assert(svg.contains("华东"))
    }

    /** 默认不显示标签。 */
    @TestCase
    public func hidesLabelsByDefault(): Unit {
        let svg = draw("""
{
  "type": "choropleth",
  "regions": [ { "id": "a", "name": "A", "value": 1, "path": "M 0 0 L 10 0 L 10 10 Z" } ]
}
""")
        @Assert(count(svg, "class=\"choropleth-label\"") == 0)
    }

    /** 正方形路径质心。 */
    @TestCase
    public func computesCentroid(): Unit {
        let center = pathCentroid("M 0 0 L 10 0 L 10 10 L 0 10 Z")
        @Assert(center.size == 2)
        @Assert(abs(center[0] - 5.0) < 1e-9)
        @Assert(abs(center[1] - 5.0) < 1e-9)
    }

    /** 无坐标路径。 */
    @TestCase
    public func rejectsInvalidPath(): Unit {
        try {
            draw("""
{
  "type": "choropleth",
  "regions": [ { "id": "a", "name": "A", "value": 1, "path": "M Z" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字区域值。 */
    @TestCase
    public func rejectsNonNumericValue(): Unit {
        try {
            draw("""
{
  "type": "choropleth",
  "regions": [ { "id": "a", "name": "A", "value": "x", "path": "M 0 0 L 10 10 Z" } ]
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
{ "type": "choropleth" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 非法颜色。 */
    @TestCase
    public func rejectsInvalidColor(): Unit {
        try {
            draw("""
{
  "type": "choropleth",
  "colorRange": ["#ffffff", "not-a-color"],
  "regions": [ { "id": "a", "name": "A", "value": 1, "path": "M 0 0 L 10 10 Z" } ]
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
{
  "type": "heatmap",
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
