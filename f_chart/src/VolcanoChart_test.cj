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
public class VolcanoChart_test {
    private func draw(json: String): String {
        VolcanoChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "volcano",
  "title": "差异表达",
  "xAxis": { "type": "linear", "title": "log2 Fold Change" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "foldChangeThreshold": 1,
  "pThreshold": 1.3,
  "legend": { "show": false },
  "series": [
    {
      "name": "基因",
      "data": [
        { "x": -2.4, "y": 4.1, "label": "GENE1" },
        { "x": 2.1, "y": 3.6, "label": "GENE2" },
        { "x": 0.3, "y": 0.8, "label": "GENE3" },
        { "x": -0.6, "y": 1.1, "label": "GENE4" },
        { "x": 1.8, "y": 2.9, "label": "GENE5" }
      ]
    }
  ]
}
"""

    /** 五个点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "volcano-point") == 5)
    }

    /** 分类计数。 */
    @TestCase
    public func marksCategories(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "volcano-up") == 2)
        @Assert(count(svg, "volcano-down") == 1)
        @Assert(count(svg, "volcano-nonsig") == 2)
    }

    /** 分类函数。 */
    @TestCase
    public func categorizes(): Unit {
        @Assert(volcanoCategory(2.1, 3.6, 1.0, 1.3) == "up")
        @Assert(volcanoCategory(-2.4, 4.1, 1.0, 1.3) == "down")
        @Assert(volcanoCategory(0.3, 0.8, 1.0, 1.3) == "none")
        @Assert(volcanoCategory(1.0, 1.3, 1.0, 1.3) == "up")
        @Assert(volcanoCategory(-1.0, 1.3, 1.0, 1.3) == "down")
    }

    /** 三条阈值线。 */
    @TestCase
    public func drawsThresholds(): Unit {
        @Assert(count(draw(sample), "class=\"volcano-threshold\"") == 3)
    }

    /** 显著项标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("GENE2"))
        @Assert(!svg.contains("GENE3"))
    }

    /** 负阈值。 */
    @TestCase
    public func rejectsThreshold(): Unit {
        let json = """
{
  "type": "volcano",
  "pThreshold": -1,
  "series": [
    { "name": "S", "data": [ { "x": 1, "y": 1 } ] }
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
  "type": "scatter",
  "series": [
    { "name": "S", "data": [ { "x": 1, "y": 1 } ] }
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
