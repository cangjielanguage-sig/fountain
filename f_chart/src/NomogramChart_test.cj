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
public class NomogramChart_test {
    private func draw(json: String): String {
        NomogramChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "nomogram",
  "title": "风险预测列线图",
  "width": 760,
  "height": 420,
  "variables": [
    { "name": "年龄", "range": [20, 80], "points": [0, 100] },
    { "name": "血压", "range": [90, 180], "points": [0, 80] },
    { "name": "BMI", "range": [18, 35], "points": [0, 60] }
  ],
  "totalPoints": [0, 240],
  "risk": [
    { "points": 0, "probability": 0.02 },
    { "points": 80, "probability": 0.15 },
    { "points": 160, "probability": 0.45 },
    { "points": 240, "probability": 0.80 }
  ]
}
"""

    /** 三个变量刻度尺。 */
    @TestCase
    public func drawsVariables(): Unit {
        @Assert(count(draw(sample), "class=\"nomogram-variable\"") == 3)
    }

    /** 总分尺与四个风险刻度。 */
    @TestCase
    public func drawsTotalAndRisk(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"nomogram-total\"") == 1)
        @Assert(count(svg, "class=\"nomogram-risk-tick\"") == 4)
    }

    /** 归一化位置与夹取。 */
    @TestCase
    public func mapsPosition(): Unit {
        @Assert(abs(nomogramPosition(120.0, 0.0, 240.0) - 0.5) < 1e-9)
        @Assert(abs(nomogramPosition(-10.0, 0.0, 240.0) - 0.0) < 1e-9)
        @Assert(abs(nomogramPosition(300.0, 0.0, 240.0) - 1.0) < 1e-9)
    }

    /** 变量范围倒置。 */
    @TestCase
    public func rejectsVariableRange(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "variables": [ { "name": "年龄", "range": [80, 20], "points": [0, 100] } ],
  "totalPoints": [0, 100],
  "risk": [ { "points": 0, "probability": 0.1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空变量。 */
    @TestCase
    public func rejectsEmptyVariables(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "variables": [],
  "totalPoints": [0, 100],
  "risk": [ { "points": 0, "probability": 0.1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 总分范围倒置。 */
    @TestCase
    public func rejectsTotalPoints(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "variables": [ { "name": "年龄", "range": [20, 80], "points": [0, 100] } ],
  "totalPoints": [240, 0],
  "risk": [ { "points": 0, "probability": 0.1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 风险点越界。 */
    @TestCase
    public func rejectsRiskPointsOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "variables": [ { "name": "年龄", "range": [20, 80], "points": [0, 100] } ],
  "totalPoints": [0, 100],
  "risk": [ { "points": 300, "probability": 0.1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 概率越界。 */
    @TestCase
    public func rejectsProbabilityOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "variables": [ { "name": "年龄", "range": [20, 80], "points": [0, 100] } ],
  "totalPoints": [0, 100],
  "risk": [ { "points": 50, "probability": 1.2 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 variables。 */
    @TestCase
    public func rejectsMissingVariables(): Unit {
        try {
            draw("""
{
  "type": "nomogram",
  "totalPoints": [0, 100],
  "risk": [ { "points": 0, "probability": 0.1 } ]
}
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
  "type": "forest",
  "variables": [],
  "totalPoints": [0, 100],
  "risk": []
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
