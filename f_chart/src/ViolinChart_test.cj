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
public class ViolinChart_test {
    private func draw(json: String): String {
        ViolinChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三组分布 → 三个轮廓与内嵌箱体。 */
    @TestCase
    public func drawsViolins(): Unit {
        let svg = draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "测量值", "data": [[8, 9, 10, 12, 14], [11, 13, 15, 17, 19], [7, 10, 13, 16, 20]] }
  ]
}
""")
        @Assert(count(svg, "class=\"violin\"") == 3)
        @Assert(count(svg, "class=\"box\"") == 3)
        @Assert(count(svg, "class=\"median\"") == 3)
    }

    /** 扁平数据视为单组。 */
    @TestCase
    public func supportsFlatData(): Unit {
        let svg = draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [8, 9, 10, 12, 14] }]
}
""")
        @Assert(count(svg, "class=\"violin\"") == 1)
    }

    /** showBox 关闭。 */
    @TestCase
    public func hidesBox(): Unit {
        let svg = draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [
    { "name": "测量值", "data": [[8, 9, 10, 12, 14], [11, 13, 15, 17, 19]], "showBox": false }
  ]
}
""")
        @Assert(count(svg, "class=\"violin\"") == 2)
        @Assert(count(svg, "class=\"box\"") == 0)
        @Assert(count(svg, "class=\"median\"") == 0)
    }

    /** 非法带宽。 */
    @TestCase
    public func rejectsInvalidBandwidth(): Unit {
        try {
            draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3], "bandwidth": -1 }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空组。 */
    @TestCase
    public func rejectsEmptyGroup(): Unit {
        try {
            draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "测量值", "data": [[1, 2, 3], []] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, "2", 3] }]
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
{ "type": "violin" }
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
  "type": "boxplot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3] }]
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
        let json = """
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "测量值", "data": [[1, 2, 3, 4], [2, 3, 4, 5]] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
