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
public class RoseChart_test {
    private func draw(json: String): String {
        RoseChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "rose",
  "title": "各品类销量占比",
  "width": 600,
  "height": 600,
  "roseType": "radius",
  "series": [
    {
      "name": "销量",
      "data": [
        { "name": "女装", "value": 40 },
        { "name": "男装", "value": 30 },
        { "name": "鞋靴", "value": 18 },
        { "name": "箱包", "value": 12 }
      ]
    }
  ]
}
"""

    /** 四个扇区。 */
    @TestCase
    public func drawsSlices(): Unit {
        @Assert(count(draw(sample), "class=\"rose-slice\"") == 4)
    }

    /** 四个标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"rose-label\"") == 4)
        @Assert(svg.contains("女装"))
    }

    /** 线性半径。 */
    @TestCase
    public func computesLinearRadius(): Unit {
        @Assert(abs(roseRadius(50.0, 100.0, 200.0, false) - 100.0) < 1e-9)
        @Assert(abs(roseRadius(100.0, 100.0, 200.0, false) - 200.0) < 1e-9)
    }

    /** 面积半径。 */
    @TestCase
    public func computesAreaRadius(): Unit {
        @Assert(abs(roseRadius(25.0, 100.0, 200.0, true) - 100.0) < 1e-9)
        @Assert(abs(roseRadius(100.0, 100.0, 200.0, true) - 200.0) < 1e-9)
    }

    /** 面积模式可绘制。 */
    @TestCase
    public func drawsAreaMode(): Unit {
        let json = """
{
  "type": "rose",
  "roseType": "area",
  "series": [
    { "name": "销量", "data": [ { "name": "A", "value": 25 }, { "name": "B", "value": 100 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"rose-slice\"") == 2)
    }

    /** 非法模式。 */
    @TestCase
    public func rejectsRoseType(): Unit {
        let json = """
{
  "type": "rose",
  "roseType": "angle",
  "series": [
    { "name": "销量", "data": [ { "name": "A", "value": 1 } ] }
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

    /** 全零数据。 */
    @TestCase
    public func rejectsZeroTotal(): Unit {
        let json = """
{
  "type": "rose",
  "series": [
    { "name": "销量", "data": [ { "name": "A", "value": 0 }, { "name": "B", "value": 0 } ] }
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

    /** 负值。 */
    @TestCase
    public func rejectsNegative(): Unit {
        let json = """
{
  "type": "rose",
  "series": [
    { "name": "销量", "data": [ { "name": "A", "value": -3 } ] }
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
  "type": "pie",
  "series": [
    { "name": "销量", "data": [ { "name": "A", "value": 1 } ] }
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
