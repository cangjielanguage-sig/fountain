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
public class FunnelChart_test {
    private func draw(json: String): String {
        FunnelChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "funnel",
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "阶段",
      "data": [
        { "name": "访问", "value": 10000 },
        { "name": "注册", "value": 6200 },
        { "name": "激活", "value": 3800 },
        { "name": "付费", "value": 1200 }
      ]
    }
  ]
}
"""

    /** 四个阶段、三条转化率、四个标签。 */
    @TestCase
    public func drawsStages(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"funnel-stage\"") == 4)
        @Assert(count(svg, "class=\"conversion-label\"") == 3)
        @Assert(count(svg, "class=\"stage-label\"") == 4)
    }

    /** 转化率计算。 */
    @TestCase
    public func computesConversion(): Unit {
        @Assert(abs(funnelConversion(10000.0, 6200.0) - 62.0) < 1e-9)
        @Assert(funnelConversion(0.0, 10.0) == 0.0)
    }

    /** 关闭转化率文本。 */
    @TestCase
    public func hidesConversion(): Unit {
        let svg = draw("""
{
  "type": "funnel",
  "showConversion": false,
  "series": [
    { "name": "阶段", "data": [{ "name": "A", "value": 10 }, { "name": "B", "value": 5 }] }
  ]
}
""")
        @Assert(count(svg, "class=\"conversion-label\"") == 0)
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "funnel",
  "series": [{ "name": "阶段", "data": [{ "name": "A", "value": -5 }] }]
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
  "type": "funnel",
  "series": [{ "name": "阶段", "data": [{ "name": "A", "value": "5" }] }]
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
{ "type": "funnel" }
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
  "type": "funnel",
  "series": [
    { "name": "甲", "data": [{ "name": "A", "value": 1 }] },
    { "name": "乙", "data": [{ "name": "B", "value": 2 }] }
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
  "type": "sankey",
  "series": [{ "name": "阶段", "data": [{ "name": "A", "value": 1 }] }]
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
