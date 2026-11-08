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
public class ForestChart_test {
    private func draw(json: String): String {
        ForestChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "forest",
  "title": "效应量汇总",
  "width": 720,
  "height": 480,
  "nullLine": 1,
  "xAxis": { "type": "log", "title": "OR（95% CI）", "min": 0.1, "max": 10 },
  "yAxis": { "type": "category", "labels": ["研究 A", "研究 B", "研究 C", "合并"] },
  "series": [
    {
      "name": "OR",
      "data": [
        { "label": "研究 A", "estimate": 0.8, "lower": 0.5, "upper": 1.3, "weight": 30 },
        { "label": "研究 B", "estimate": 1.5, "lower": 1.1, "upper": 2.1, "weight": 45 },
        { "label": "研究 C", "estimate": 1.1, "lower": 0.7, "upper": 1.8, "weight": 25 },
        { "label": "合并", "estimate": 1.2, "lower": 0.95, "upper": 1.5, "weight": 100 }
      ]
    }
  ]
}
"""

    /** 四个研究的区间与估计值。 */
    @TestCase
    public func drawsRows(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"forest-ci\"") == 4)
        @Assert(count(svg, "class=\"forest-point\"") == 4)
    }

    /** 无效线。 */
    @TestCase
    public func drawsNullLine(): Unit {
        @Assert(count(draw(sample), "class=\"forest-null\"") == 1)
    }

    /** 权重映射端点。 */
    @TestCase
    public func mapsMarkerSize(): Unit {
        @Assert(abs(forestMarkerSize(0.0, 100.0) - 6.0) < 1e-9)
        @Assert(abs(forestMarkerSize(100.0, 100.0) - 14.0) < 1e-9)
    }

    /** 对数位置。 */
    @TestCase
    public func mapsLogPosition(): Unit {
        @Assert(abs(forestLogPosition(0.1, 0.1, 10.0) - 0.0) < 1e-9)
        @Assert(abs(forestLogPosition(1.0, 0.1, 10.0) - 0.5) < 1e-9)
        @Assert(abs(forestLogPosition(10.0, 0.1, 10.0) - 1.0) < 1e-9)
    }

    /** 对数刻度包含十的幂与端点。 */
    @TestCase
    public func computesLogTicks(): Unit {
        let ticks = forestLogTicks(0.1, 10.0, 10.0)
        @Assert(ticks.size == 3)
        @Assert(abs(ticks[0] - 0.1) < 1e-9)
        @Assert(abs(ticks[1] - 1.0) < 1e-9)
        @Assert(abs(ticks[2] - 10.0) < 1e-9)
    }

    /** 区间倒置。 */
    @TestCase
    public func rejectsInvertedCI(): Unit {
        try {
            draw("""
{
  "type": "forest",
  "series": [ { "name": "OR", "data": [ { "label": "A", "estimate": 1.5, "lower": 2, "upper": 1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 对数轴下的非正端点。 */
    @TestCase
    public func rejectsNonPositiveLogValue(): Unit {
        try {
            draw("""
{
  "type": "forest",
  "xAxis": { "type": "log", "min": 0.1, "max": 10 },
  "series": [ { "name": "OR", "data": [ { "label": "A", "estimate": 1, "lower": 0, "upper": 2 } ] } ]
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
  "type": "forest",
  "series": [ { "name": "OR", "data": [ { "label": "A", "estimate": 1, "lower": 0.5, "upper": 2, "weight": -1 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        try {
            draw("""
{
  "type": "forest",
  "series": [ { "name": "OR", "data": [] } ]
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
{ "type": "forest" }
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
  "type": "bar",
  "series": [ { "name": "OR", "data": [] } ]
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
