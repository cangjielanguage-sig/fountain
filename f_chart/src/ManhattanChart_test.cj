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
public class ManhattanChart_test {
    private func draw(json: String): String {
        ManhattanChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "manhattan",
  "title": "GWAS 曼哈顿图",
  "xAxis": { "type": "linear", "title": "染色体位置" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "threshold": 5.0,
  "legend": { "show": false },
  "series": [
    {
      "name": "SNP",
      "data": [
        { "x": 1000, "y": 2.1, "chromosome": "1" },
        { "x": 2500, "y": 4.8, "chromosome": "1" },
        { "x": 5200, "y": 6.2, "chromosome": "2" },
        { "x": 7800, "y": 1.5, "chromosome": "3" },
        { "x": 9900, "y": 5.4, "chromosome": "3" }
      ]
    }
  ]
}
"""

    /** 五个点。 */
    @TestCase
    public func drawsPoints(): Unit {
        @Assert(count(draw(sample), "class=\"manhattan-point\"") == 5)
    }

    /** 一条阈值线。 */
    @TestCase
    public func drawsThreshold(): Unit {
        @Assert(count(draw(sample), "class=\"manhattan-threshold\"") == 1)
    }

    /** 单染色体位置不变。 */
    @TestCase
    public func keepsSingleChromosome(): Unit {
        let positions = manhattanPositions([10.0, 20.0, 5.0], ["1", "1", "1"], 100.0)
        @Assert(positions.size == 3)
        @Assert(abs(positions[0] - 10.0) < 1e-9)
        @Assert(abs(positions[1] - 20.0) < 1e-9)
        @Assert(abs(positions[2] - 5.0) < 1e-9)
    }

    /** 染色体间隔。 */
    @TestCase
    public func insertsGap(): Unit {
        let positions = manhattanPositions(
            [1000.0, 2500.0, 5200.0, 7800.0, 9900.0],
            ["1", "1", "2", "3", "3"],
            100.0
        )
        @Assert(abs(positions[0] - 1000.0) < 1e-9)
        @Assert(abs(positions[1] - 2500.0) < 1e-9)
        // 第二组起点 = 第一组最小 1000 + 跨度 1500 + gap 100
        @Assert(abs(positions[2] - 2600.0) < 1e-9)
        // 第三组起点 = 2600 + 跨度 0 + gap 100
        @Assert(abs(positions[3] - 2700.0) < 1e-9)
        @Assert(abs(positions[4] - 4800.0) < 1e-9)
    }

    /** 缺少染色体。 */
    @TestCase
    public func rejectsMissingChromosome(): Unit {
        let json = """
{
  "type": "manhattan",
  "series": [
    { "name": "S", "data": [ { "x": 1, "y": 2 } ] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 负间距。 */
    @TestCase
    public func rejectsNegativeGap(): Unit {
        let json = """
{
  "type": "manhattan",
  "chromosomeGap": -10,
  "series": [
    { "name": "S", "data": [ { "x": 1, "y": 2, "chromosome": "1" } ] }
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
  "type": "volcano",
  "series": [
    { "name": "S", "data": [ { "x": 1, "y": 2, "chromosome": "1" } ] }
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
