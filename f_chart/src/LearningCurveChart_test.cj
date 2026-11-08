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
public class LearningCurveChart_test {
    private func draw(json: String): String {
        LearningCurveChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "learning-curve",
  "title": "学习曲线",
  "xAxis": { "type": "linear", "title": "训练样本量" },
  "yAxis": { "type": "linear", "title": "准确率", "min": 0, "max": 1 },
  "metric": "score",
  "series": [
    { "name": "训练集", "data": [{ "x": 100, "y": 0.72 }, { "x": 500, "y": 0.86 }, { "x": 1000, "y": 0.91 }, { "x": 2000, "y": 0.94 }] },
    { "name": "验证集", "data": [{ "x": 100, "y": 0.60 }, { "x": 500, "y": 0.78 }, { "x": 1000, "y": 0.84 }, { "x": 2000, "y": 0.87 }] }
  ]
}
"""

    /** 两条曲线与八个点。 */
    @TestCase
    public func drawsCurves(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"learning-line\"") == 2)
        @Assert(count(svg, "class=\"learning-point\"") == 8)
    }

    /** 图例与轴。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("训练集"))
        @Assert(svg.contains("验证集"))
        @Assert(svg.contains("训练样本量"))
    }

    /** 损失指标。 */
    @TestCase
    public func drawsLossMetric(): Unit {
        let json = """
{
  "type": "learning-curve",
  "metric": "loss",
  "series": [
    { "name": "训练集", "data": [ { "x": 1, "y": 0.5 }, { "x": 2, "y": 0.3 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"learning-line\"") == 1)
    }

    /** 标准差带。 */
    @TestCase
    public func drawsBand(): Unit {
        let json = """
{
  "type": "learning-curve",
  "shade": true,
  "series": [
    {
      "name": "训练集",
      "data": [ { "x": 1, "y": 0.5 }, { "x": 2, "y": 0.7 }, { "x": 3, "y": 0.8 } ],
      "std": [0.05, 0.04, 0.03]
    }
  ]
}
"""
        @Assert(count(draw(json), "class=\"learning-band\"") == 1)
    }

    /** 无标准差数据时不画带。 */
    @TestCase
    public func skipsBandWithoutStd(): Unit {
        let json = """
{
  "type": "learning-curve",
  "shade": true,
  "series": [
    { "name": "训练集", "data": [ { "x": 1, "y": 0.5 }, { "x": 2, "y": 0.7 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"learning-band\"") == 0)
    }

    /** 标准差长度不符。 */
    @TestCase
    public func rejectsStdLength(): Unit {
        let json = """
{
  "type": "learning-curve",
  "series": [
    {
      "name": "训练集",
      "data": [ { "x": 1, "y": 0.5 }, { "x": 2, "y": 0.7 } ],
      "std": [0.05]
    }
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

    /** 非法指标。 */
    @TestCase
    public func rejectsMetric(): Unit {
        let json = """
{
  "type": "learning-curve",
  "metric": "accuracy",
  "series": [
    { "name": "训练集", "data": [ { "x": 1, "y": 0.5 } ] }
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

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "learning-curve",
  "series": [
    { "name": "训练集", "data": [] }
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
  "type": "lift",
  "series": [
    { "name": "训练集", "data": [ { "x": 1, "y": 0.5 } ] }
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
