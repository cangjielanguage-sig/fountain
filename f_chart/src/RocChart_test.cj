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
public class RocChart_test {
    private func draw(json: String): String {
        RocChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "roc",
  "title": "ROC 曲线",
  "xAxis": { "type": "linear", "title": "假阳性率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "真阳性率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A（AUC=0.86）",
      "auc": 0.86,
      "data": [
        { "x": 0.0, "y": 0.0 }, { "x": 0.1, "y": 0.45 }, { "x": 0.2, "y": 0.65 },
        { "x": 0.4, "y": 0.80 }, { "x": 0.6, "y": 0.90 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
"""

    /** 曲线、点与对角线。 */
    @TestCase
    public func drawsCurveAndDiagonal(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"roc-point\"") == 6)
        @Assert(count(svg, "class=\"roc-line\"") == 1)
        @Assert(count(svg, "class=\"roc-diagonal\"") == 1)
    }

    /** 关闭对角线。 */
    @TestCase
    public func hidesDiagonal(): Unit {
        let svg = draw("""
{
  "type": "roc",
  "diagonal": false,
  "series": [ { "name": "模型", "data": [ { "x": 0, "y": 0 }, { "x": 1, "y": 1 } ] } ]
}
""")
        @Assert(count(svg, "class=\"roc-diagonal\"") == 0)
        @Assert(count(svg, "class=\"roc-point\"") == 2)
    }

    /** AUC 标注。 */
    @TestCase
    public func drawsAuc(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"roc-auc\"") == 1)
        @Assert(svg.contains("0.86"))
    }

    /** AUC 越界。 */
    @TestCase
    public func rejectsAucOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "roc",
  "series": [ { "name": "模型", "auc": 1.2, "data": [ { "x": 0, "y": 0 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 工作点越界。 */
    @TestCase
    public func rejectsPointOutOfRange(): Unit {
        try {
            draw("""
{
  "type": "roc",
  "series": [ { "name": "模型", "data": [ { "x": 1.5, "y": 0.5 } ] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数字工作点。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "roc",
  "series": [ { "name": "模型", "data": [ { "x": 0, "y": "a" } ] } ]
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
  "type": "roc",
  "series": [ { "name": "模型", "data": [] } ]
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
{ "type": "roc" }
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
  "type": "pr",
  "series": [ { "name": "模型", "data": [] } ]
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
