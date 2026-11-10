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
public class LollipopChart_test {
    private func draw(json: String): String {
        LollipopChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "lollipop",
  "title": "各渠道转化率",
  "xAxis": { "type": "category", "labels": ["搜索", "社交", "邮件", "直访", "联盟"] },
  "yAxis": { "type": "linear", "title": "转化率", "min": 0, "labelFormat": "{value}%" },
  "legend": { "show": false },
  "series": [
    { "name": "转化率", "data": [4.2, 2.8, 3.6, 5.1, 1.9], "symbolSize": 8 }
  ]
}
"""

    /** 五根茎。 */
    @TestCase
    public func drawsStems(): Unit {
        @Assert(count(draw(sample), "class=\"lollipop-stem\"") == 5)
    }

    /** 五个圆头。 */
    @TestCase
    public func drawsHeads(): Unit {
        @Assert(count(draw(sample), "class=\"lollipop-head\"") == 5)
    }

    /** 轴与类目。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("转化率"))
        @Assert(svg.contains("搜索"))
        @Assert(svg.contains("0%"))
    }

    /** 缺测跳过。 */
    @TestCase
    public func skipsNulls(): Unit {
        let json = """
{
  "type": "lollipop",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "S", "data": [4.2, null, 3.6] }
  ]
}
"""
        let svg = draw(json)
        @Assert(count(svg, "class=\"lollipop-stem\"") == 2)
        @Assert(count(svg, "class=\"lollipop-head\"") == 2)
    }

    /** 非法点大小。 */
    @TestCase
    public func rejectsSymbolSize(): Unit {
        let json = """
{
  "type": "lollipop",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1], "symbolSize": 0 }
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

    /** 类目长度不匹配。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        let json = """
{
  "type": "lollipop",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "series": [
    { "name": "S", "data": [1, 2] }
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
  "type": "dot",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1] }
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
