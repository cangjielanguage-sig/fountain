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
package fountain::fprobe.tui

import fountain::f_chart.tui.{TuiBarChart, TuiCellChart, TuiLineChart}
import fountain::f_data.{JsonArray, JsonObject}

/**
 * 把历史序列适配成 `fountain::f_chart.tui` 的字符画。
 *
 * 只画一条序列：同一页面的指标单位可能不同（% 与字节），混在一张图里 Y 轴没有意义。
 * 横轴固定为类目轴，标签由图表实现自动生成 `1..N`。
 *
 * 尺寸不足或图表实现抛异常时返回 `None`，由调用方回退到单行 sparkline。
 */
public class ChartPanel {
    public static let MIN_WIDTH: Int64 = 20
    public static let MIN_HEIGHT: Int64 = 8

    /** 只有折线与柱状图参与 TUI 渲染。 */
    public static func supports(chartType: String): Bool {
        chartType == "line" || chartType == "bar"
    }

    /** 构造图表 JSON；不满足尺寸或没有有效数值时返回 `None`。 */
    public static func chartJson(chartType: String, seriesName: String, values: Array<Float64>,
        width: Int64, height: Int64): ?JsonObject {
        if (!supports(chartType) || values.isEmpty() || width < MIN_WIDTH || height < MIN_HEIGHT) {
            return None<JsonObject>
        }
        var usable = false
        for (value in values) {
            if (value == value) {
                usable = true
                break
            }
        }
        if (!usable) {
            return None<JsonObject>
        }
        let root = JsonObject()
        root.add("type", chartType)
        root.add("title", "")
        root.add("width", width)
        root.add("height", height)
        let axis = JsonObject()
        axis.add("type", "category")
        axis.add("labels", JsonArray())
        root.add("xAxis", axis)
        let data = JsonArray()
        for (value in values) {
            data.add(value)
        }
        let item = JsonObject()
        item.add("name", seriesName)
        item.add("data", data)
        let series = JsonArray()
        series.add(item)
        root.add("series", series)
        Some(root)
    }

    /** 渲染成逐单元格符号矩阵；失败返回 `None`。 */
    public static func render(chartType: String, seriesName: String, values: Array<Float64>,
        width: Int64, height: Int64): ?Array<Array<String>> {
        let json = match (chartJson(chartType, seriesName, values, width, height)) {
            case Some(value) => value
            case None => return None<Array<Array<String>>>
        }
        try {
            let chart: TuiCellChart = if (chartType == "bar") {
                TuiBarChart()
            } else {
                TuiLineChart()
            }
            Some(chart.drawCells(json))
        } catch (e: Exception) {
            eprintln("fprobe tui: 图表渲染失败: ${e.message}")
            None<Array<Array<String>>>
        } catch (e: Error) {
            eprintln("fprobe tui: 图表渲染失败: ${e.message}")
            None<Array<Array<String>>>
        }
    }
}
