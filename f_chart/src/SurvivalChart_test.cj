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
public class SurvivalChart_test {
    private func draw(json: String): String {
        SurvivalChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "survival",
  "title": "Kaplan-Meier 生存曲线",
  "xAxis": { "type": "linear", "title": "时间（月）", "min": 0 },
  "yAxis": { "type": "linear", "title": "生存率", "min": 0, "max": 1 },
  "confidence": false,
  "series": [
    {
      "name": "治疗组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.92 },
        { "time": 12, "survival": 0.80 }, { "time": 18, "survival": 0.70, "censored": true },
        { "time": 24, "survival": 0.62 }
      ]
    },
    {
      "name": "对照组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.85 },
        { "time": 12, "survival": 0.68 }, { "time": 18, "survival": 0.55 },
        { "time": 24, "survival": 0.40 }
      ]
    }
  ]
}
"""

    /** 两条阶梯线与十个点。 */
    @TestCase
    public func drawsTwoSeries(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"survival-line\"") == 2)
        @Assert(count(svg, "class=\"survival-point\"") == 10)
    }

    /** 删失标记。 */
    @TestCase
    public func drawsCensorMarkers(): Unit {
        @Assert(count(draw(sample), "class=\"survival-censor\"") == 1)
    }

    /** 关闭删失标记。 */
    @TestCase
    public func hidesCensors(): Unit {
        let svg = draw("""
{
  "type": "survival",
  "showCensors": false,
  "series": [ { "name": "组", "data": [
    { "time": 0, "survival": 1 }, { "time": 5, "survival": 0.8, "censored": true }
  ] } ]
}
""")
        @Assert(count(svg, "class=\"survival-censor\"") == 0)
    }

    /** 默认不画置信带。 */
    @TestCase
    public func omitsBandsByDefault(): Unit {
        @Assert(count(draw(sample), "class=\"survival-band\"") == 0)
    }

    /** 开启置信带。 */
    @TestCase
    public func drawsBands(): Unit {
        let svg = draw("""
{
  "type": "survival",
  "confidence": true,
  "series": [
    { "name": "A", "data": [ { "time": 0, "survival": 1 }, { "time": 5, "survival": 0.8 } ] },
    { "name": "B", "data": [ { "time": 0, "survival": 1 }, { "time": 5, "survival": 0.6 } ] }
  ]
}
""")
        @Assert(count(svg, "class=\"survival-band\"") == 2)
    }

    /** 置信区间近似。 */
    @TestCase
    public func computesConfidence(): Unit {
        let bounds = survivalConfidence(0.5, 100)
        @Assert(abs(bounds[0] - 0.402) < 1e-6)
        @Assert(abs(bounds[1] - 0.598) < 1e-6)
    }

    /** 负时间。 */
    @TestCase
    public func rejectsNegativeTime(): Unit {
        try {
            draw("""
{
  "type": "survival",
  "series": [ { "name": "组", "data": [ { "time": -1, "survival": 0.5 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 生存率越界。 */
    @TestCase
    public func rejectsSurvivalOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "survival",
  "series": [ { "name": "组", "data": [ { "time": 1, "survival": 1.2 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 某系列数据为空。 */
    @TestCase
    public func rejectsEmptySeriesData(): Unit {
        try {
            draw("""
{
  "type": "survival",
  "series": [ { "name": "组", "data": [] } ]
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
{ "type": "survival" }
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
  "type": "line",
  "series": [ { "name": "组", "data": [] } ]
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
