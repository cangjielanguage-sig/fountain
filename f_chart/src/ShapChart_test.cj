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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class ShapChart_test {
    private func draw(json: String): String {
        ShapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "shap",
  "title": "单样本 SHAP 解释",
  "width": 720,
  "height": 440,
  "features": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    {
      "name": "SHAP",
      "data": [
        { "feature": "年龄", "value": 0.32 },
        { "feature": "血压", "value": -0.18 },
        { "feature": "BMI", "value": 0.12 },
        { "feature": "血糖", "value": -0.05 }
      ]
    }
  ]
}
"""

    /** 四个条形，两正两负。 */
    @TestCase
    public func drawsBars(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"shap-bar shap-positive\"") == 2)
        @Assert(count(svg, "class=\"shap-bar shap-negative\"") == 2)
    }

    /** 零基线一条。 */
    @TestCase
    public func drawsZeroLine(): Unit {
        @Assert(count(draw(sample), "class=\"shap-zero\"") == 1)
    }

    /** 每个条形一个数值标签。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"shap-label\"") == 4)
        @Assert(svg.contains("0.32"))
        @Assert(svg.contains("-0.18"))
    }

    /** 特征名全部输出。 */
    @TestCase
    public func drawsFeatures(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"shap-feature\"") == 4)
        @Assert(svg.contains("年龄"))
        @Assert(svg.contains("血糖"))
    }

    /** 按绝对值降序排序。 */
    @TestCase
    public func sortsByAbsoluteValue(): Unit {
        let items = ArrayList<ShapContribution>()
        items.add(ShapContribution("年龄", 0.32))
        items.add(ShapContribution("血压", -0.18))
        items.add(ShapContribution("BMI", 0.12))
        items.add(ShapContribution("血糖", -0.05))
        let ordered = shapOrder(items)
        @Assert(ordered[0].feature == "年龄")
        @Assert(ordered[1].feature == "血压")
        @Assert(ordered[2].feature == "BMI")
        @Assert(ordered[3].feature == "血糖")
    }

    /** 绝对值相同时保持输入顺序。 */
    @TestCase
    public func keepsStableOrder(): Unit {
        let items = ArrayList<ShapContribution>()
        items.add(ShapContribution("A", 0.2))
        items.add(ShapContribution("B", -0.2))
        let ordered = shapOrder(items)
        @Assert(ordered[0].feature == "A")
        @Assert(ordered[1].feature == "B")
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "shap",
  "features": [],
  "series": [ { "name": "SHAP", "data": [] } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺少 value。 */
    @TestCase
    public func rejectsMissingValue(): Unit {
        let json = """
{
  "type": "shap",
  "series": [ { "name": "SHAP", "data": [ { "feature": "年龄" } ] } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 特征名为空。 */
    @TestCase
    public func rejectsEmptyFeature(): Unit {
        let json = """
{
  "type": "shap",
  "series": [ { "name": "SHAP", "data": [ { "feature": "", "value": 0.2 } ] } ]
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
  "type": "pdp",
  "series": [ { "name": "SHAP", "data": [ { "feature": "年龄", "value": 0.2 } ] } ]
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
