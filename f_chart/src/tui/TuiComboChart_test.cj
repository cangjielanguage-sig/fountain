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
package fountain::f_chart.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_chart.*
import fountain::f_data.json.*

@Test
public class TuiComboChart_test {
    private func draw(json: String): String {
        TuiComboChart().draw(JsonValue.fromStr(json).asObject())
    }

    private let sample: String = """
{
  "type": "combo",
  "title": "销售额与增长率",
  "width": 72,
  "height": 20,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "yAxis2": { "type": "linear", "labelFormat": "{value}%" },
  "series": [
    { "name": "产品 A", "type": "bar", "data": [120, 150, 170, 180] },
    { "name": "增长", "type": "line", "axis": "right", "data": [8, 14, 18, 22] },
    { "name": "样本", "type": "scatter", "axis": "right", "data": [10, 12, 17, 21] }
  ]
}
"""

    /** 柱 + 线 + 散点同时出现。 */
    @TestCase
    public func drawsThreeTypes(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("█"))
        @Assert(plain.contains("*"))
        @Assert(plain.contains("o"))
        @Assert(plain.contains("产品 A"))
        @Assert(plain.contains("增长"))
        @Assert(plain.contains("样本"))
    }

    /** 右轴刻度标签存在。 */
    @TestCase
    public func drawsRightAxis(): Unit {
        let plain = tuiStripAnsi(draw(sample))
        @Assert(plain.contains("%"))
    }

    /** 多个柱系列按系列取不同颜色和符号。 */
    @TestCase
    public func colorsEachBarSeries(): Unit {
        let json = """
{
  "type": "combo",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "柱1", "type": "bar", "data": [10, 20] },
    { "name": "柱2", "type": "bar", "data": [15, 25] },
    { "name": "线", "type": "line", "data": [12, 22] }
  ]
}
"""
        let svg = draw(json)
        let plain = tuiStripAnsi(svg)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[38;2;242;142;43m"))
        @Assert(svg.contains("\u{1B}[38;2;225;87;89m"))
        @Assert(plain.contains("█"))
        @Assert(plain.contains("▓"))
        @Assert(plain.contains("*"))
    }

    /** 分组柱与堆叠柱混合。 */
    @TestCase
    public func mixesBarFamilies(): Unit {
        let json = """
{
  "type": "combo",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "分组", "type": "grouped-bar", "data": [10, 20] },
    { "name": "堆叠1", "type": "stacked-bar", "stack": "s", "data": [5, 8] },
    { "name": "堆叠2", "type": "stacked-bar", "stack": "s", "data": [4, 6] }
  ]
}
"""
        let svg = draw(json)
        @Assert(svg.contains("\u{1B}[38;2;78;121;167m"))
        @Assert(svg.contains("\u{1B}[38;2;242;142;43m"))
        @Assert(tuiStripAnsi(svg).contains("█"))
    }

    /** 百分比堆叠叠加折线。 */
    @TestCase
    public func mixesPercentAndLine(): Unit {
        let json = """
{
  "type": "combo",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "份额1", "type": "percent-stacked-bar", "data": [30, 40] },
    { "name": "份额2", "type": "percent-stacked-bar", "data": [70, 60] },
    { "name": "趋势", "type": "line", "data": [50, 55] }
  ]
}
"""
        let plain = tuiStripAnsi(draw(json))
        @Assert(plain.contains("█"))
        @Assert(plain.contains("*"))
    }

    /** 非法系列类型。 */
    @TestCase
    public func rejectsBadSeriesType(): Unit {
        let json = """
{
  "type": "combo",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [ { "name": "S", "type": "area", "data": [1] } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非类目横轴。 */
    @TestCase
    public func rejectsNumericAxis(): Unit {
        let json = """
{
  "type": "combo",
  "xAxis": { "type": "linear" },
  "series": [ { "name": "S", "type": "line", "data": [ { "x": 1, "y": 2 } ] } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }
}
