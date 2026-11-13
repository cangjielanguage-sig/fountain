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
public class StemLeafChart_test {
    private func draw(json: String): String {
        StemLeafChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 经典样本分为五行，茎 6 的叶正确。 */
    @TestCase
    public func groupsByStem(): Unit {
        let rows = stemLeafRows(
            [52.0, 55.0, 58.0, 61.0, 63.0, 63.0, 67.0, 70.0, 72.0, 75.0,
             78.0, 81.0, 85.0, 88.0, 92.0, 96.0],
            10.0,
            1
        )
        @Assert(rows.size == 5)
        @Assert(rows[0].stem == 5)
        @Assert(rows[1].stem == 6)
        @Assert(rows[1].leaves.size == 4)
        @Assert(rows[1].leaves[0] == 1)
        @Assert(rows[1].leaves[1] == 3)
        @Assert(rows[1].leaves[2] == 3)
        @Assert(rows[1].leaves[3] == 7)
    }

    /** 乱序输入的叶按升序排列。 */
    @TestCase
    public func sortsLeaves(): Unit {
        let rows = stemLeafRows([72.0, 61.0, 75.0, 63.0], 10.0, 1)
        @Assert(rows.size == 2)
        @Assert(rows[0].leaves[0] == 1)
        @Assert(rows[0].leaves[1] == 3)
        @Assert(rows[1].leaves[0] == 2)
        @Assert(rows[1].leaves[1] == 5)
    }

    /** 五行文本输出。 */
    @TestCase
    public func drawsRows(): Unit {
        let svg = draw("""
{
  "type": "stem-leaf",
  "width": 600,
  "height": 520,
  "stemUnit": 10,
  "leafDigits": 1,
  "series": [
    { "name": "成绩", "data": [52, 55, 58, 61, 63, 63, 67, 70, 72, 75, 78, 81, 85, 88, 92, 96] }
  ]
}
""")
        @Assert(count(svg, "class=\"stem-leaf-row\"") == 5)
        @Assert(count(svg, "class=\"stem-leaf-leaves\"") == 5)
        @Assert(svg.contains("茎"))
        @Assert(svg.contains("叶"))
    }

    /** 叶不会进位到 10。 */
    @TestCase
    public func clampsLeaf(): Unit {
        let rows = stemLeafRows([59.99], 10.0, 1)
        @Assert(rows.size == 1)
        @Assert(rows[0].leaves[0] == 9)
    }

    /** 非法茎单位。 */
    @TestCase
    public func rejectsInvalidStemUnit(): Unit {
        try {
            draw("""
{
  "type": "stem-leaf",
  "stemUnit": 0,
  "series": [{ "name": "成绩", "data": [52, 61] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法叶位数。 */
    @TestCase
    public func rejectsInvalidLeafDigits(): Unit {
        try {
            draw("""
{
  "type": "stem-leaf",
  "leafDigits": -1,
  "series": [{ "name": "成绩", "data": [52, 61] }]
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
  "type": "stem-leaf",
  "series": [{ "name": "成绩", "data": [52, "61"] }]
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
{ "type": "stem-leaf" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 多个系列。 */
    @TestCase
    public func rejectsMultipleSeries(): Unit {
        try {
            draw("""
{
  "type": "stem-leaf",
  "series": [
    { "name": "甲", "data": [52, 61] },
    { "name": "乙", "data": [55, 63] }
  ]
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
  "type": "histogram",
  "series": [{ "name": "成绩", "data": [52, 61] }]
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
  "type": "stem-leaf",
  "series": [{ "name": "成绩", "data": [52, 55, 58, 61, 63] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
