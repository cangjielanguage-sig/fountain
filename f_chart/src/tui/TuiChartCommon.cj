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

import std.collection.ArrayList
import std.math.*
import fountain::f_chart.*

/** 系列颜色：显式颜色优先，否则取主题调色板。 */
internal func tuiSeriesColor(
    config: ChartConfig,
    index: Int64,
    explicitColor: String
): String {
    if (explicitColor.isEmpty()) {
        config.theme.colorAt(index)
    } else {
        explicitColor
    }
}

/** 类目标签：优先使用 xAxis.labels，否则生成 1..n。 */
internal func tuiResolveLabels(config: ChartConfig, count: Int64): Array<String> {
    if (!config.xAxis.labels.isEmpty()) {
        return config.xAxis.labels
    }
    let labels = ArrayList<String>()
    for (index in 0..count) {
        labels.add((index + 1).toString())
    }
    labels.toArray()
}

/** 从数值集合计算值域；`includeZero` 用于柱状图强制包含 0。 */
internal func tuiValueRange(
    values: Array<Float64>,
    axis: ChartAxis,
    includeZero: Bool
): Array<Float64> {
    var min = 0.0
    var max = 0.0
    var hasData = false
    for (value in values) {
        if (!hasData) {
            min = value
            max = value
            hasData = true
        } else {
            min = minFloat(min, value)
            max = maxFloat(max, value)
        }
    }
    if (!hasData) {
        return [0.0, 1.0]
    }
    if (includeZero) {
        min = minFloat(min, 0.0)
        max = maxFloat(max, 0.0)
    }
    match (axis.min) {
        case Some(value) => min = value
        case None => ()
    }
    match (axis.max) {
        case Some(value) => max = value
        case None => ()
    }
    if (max <= min) {
        max = min + 1.0
    }
    [min, max]
}

/** 计算刻度值。 */
internal func tuiTicks(range: Array<Float64>, axis: ChartAxis): Array<Float64> {
    if (!axis.values.isEmpty()) {
        axis.values
    } else {
        chartNiceTicks(range[0], range[1], axis.tickCount)
    }
}

/** 纵轴刻度标签的最大显示宽度。 */
internal func tuiTickLabelWidth(ticks: Array<Float64>, axis: ChartAxis): Int64 {
    var width: Int64 = 1
    for (tick in ticks) {
        width = tuiMaxInt64(
            width,
            tuiDisplayWidth(chartFormatTick(tick, axis.labelFormat))
        )
    }
    width
}

/** 是否显示图例：配置开启且至少有一个具名系列。 */
internal func tuiLegendVisible(config: ChartConfig, names: Array<String>): Bool {
    if (!config.legend.show) {
        return false
    }
    for (name in names) {
        if (!name.isEmpty()) {
            return true
        }
    }
    false
}

/** 系列填充符号：在无色终端里也能区分多系列柱体。 */
internal func tuiSeriesSymbol(index: Int64): String {
    let symbols = ["█", "▓", "▒", "░"]
    symbols[index % symbols.size]
}

/** 从 fromRow 到 toRow（含两端）填充 `width` 列的柱体。 */
internal func tuiFillColumn(
    canvas: TuiCanvas,
    x: Int64,
    width: Int64,
    fromRow: Int64,
    toRow: Int64,
    color: String,
    symbol!: String = "█"
): Unit {
    let top = tuiMinInt64(fromRow, toRow)
    let bottom = tuiMaxInt64(fromRow, toRow)
    for (row in top..bottom + 1) {
        for (column in x..x + width) {
            canvas.set(column, row, symbol, color)
        }
    }
}

internal func tuiMinInt64(left: Int64, right: Int64): Int64 {
    if (left < right) { left } else { right }
}

internal func tuiMaxInt64(left: Int64, right: Int64): Int64 {
    if (left > right) { left } else { right }
}
