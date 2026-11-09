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

import std.fs.{Directory, File, Path, exists}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_chart.Chart
import fountain::f_data.json.*

/**
 * TUI 样例画廊：用真实 JSON 渲染 M1–M7，并把字符画写入 `charts/`。
 *
 * 运行 `cd f_chart && cjpm test --skip-build` 后，`f_chart/charts` 下会生成
 * 7 个可直接用文本编辑器打开的 `.tui.txt` 文件（ANSI 颜色已剥离）。
 */
@Test
public class TuiGallery_test {
    private func save(name: String, chart: Chart, json: String): Unit {
        let output = chart.draw(JsonValue.fromStr(json).asObject())
        @Assert(output.contains("\u{1B}["))
        let plain = tuiStripAnsi(output)
        @Assert(plain.contains("└"))
        @Assert(plain.contains("─"))
        let directory = Path("charts")
        if (!exists(directory)) {
            Directory.create(directory, recursive: true)
        }
        File.writeTo(Path("charts/${name}.tui.txt"), plain.toArray())
        File.writeTo(Path("charts/${name}.tui.color.txt"), output.toArray())
    }

    /** M1 柱状图。 */
    @TestCase
    public func m001Bar(): Unit {
        save("M001-bar", TuiBarChart(), """
{
  "type": "bar",
  "title": "月度销售额",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["一月", "二月", "三月", "四月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "销售额", "data": [120, 200, 150, 180] }
  ]
}
""")
    }

    /** M2 分组柱状图。 */
    @TestCase
    public func m002GroupedBar(): Unit {
        save("M002-grouped-bar", TuiGroupedBarChart(), """
{
  "type": "grouped-bar",
  "title": "各季度产品销售额",
  "width": 64,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "产品 A", "data": [120, 150, 170, 160] },
    { "name": "产品 B", "data": [90, 110, 130, 140] }
  ]
}
""")
    }

    /** M3 堆叠柱状图。 */
    @TestCase
    public func m003StackedBar(): Unit {
        save("M003-stacked-bar", TuiStackedBarChart(), """
{
  "type": "stacked-bar",
  "title": "各区收入构成",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "线上", "stack": "revenue", "data": [120, 90, 70] },
    { "name": "门店", "stack": "revenue", "data": [80, 70, 60] },
    { "name": "分销", "stack": "revenue", "data": [40, 35, 30] }
  ]
}
""")
    }

    /** M4 百分比堆叠柱状图。 */
    @TestCase
    public func m004PercentStackedBar(): Unit {
        save("M004-percent-stacked-bar", TuiPercentStackedBarChart(), """
{
  "type": "percent-stacked-bar",
  "title": "各渠道占比",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "series": [
    { "name": "线上", "data": [60, 70, 80] },
    { "name": "门店", "data": [30, 20, 15] },
    { "name": "分销", "data": [10, 10, 5] }
  ]
}
""")
    }

    /** M5 折线图。 */
    @TestCase
    public func m005Line(): Unit {
        save("M005-line", TuiLineChart(), """
{
  "type": "line",
  "title": "周活跃用户",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "活跃", "data": [120, 160, 140, 200, 180] }
  ]
}
""")
    }

    /** M6 散点图。 */
    @TestCase
    public func m006Scatter(): Unit {
        save("M006-scatter", TuiScatterChart(), """
{
  "type": "scatter",
  "title": "身高体重",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "linear", "title": "身高" },
  "yAxis": { "type": "linear", "title": "体重" },
  "series": [
    { "name": "样本", "data": [
      { "x": 160, "y": 55 }, { "x": 165, "y": 60 }, { "x": 170, "y": 65 },
      { "x": 175, "y": 70 }, { "x": 180, "y": 75 }
    ] }
  ]
}
""")
    }

    /** M7 组合图：柱 + 线 + 散点。 */
    @TestCase
    public func m007Combo(): Unit {
        save("M007-combo", TuiComboChart(), """
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
""")
    }
}
