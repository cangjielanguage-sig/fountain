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
import fountain::f_data.json.*

/** M6 散点图的 TUI 实现。 */
public class TuiScatterChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(
            data, "scatter", defaultWidth: 80.0, defaultHeight: 24.0
        )
        if (config.xAxis.axisType == "category") {
            throw chartInvalidValue("xAxis.type", "散点图需要 linear 或 time 横轴")
        }
        let root = ChartJson.of(data)
        let series = tuiParsePointSeries(config, root.requiredArray("series"))
        let yValues = tuiPointYValues(series)
        if (yValues.isEmpty()) {
            throw chartInvalidValue("series.data", "至少需要一个有效 y 值")
        }
        let xRange = tuiValueRange(tuiPointXValues(series), config.xAxis, false)
        let yRange = tuiValueRange(yValues, config.yAxis, false)
        let yTicks = tuiTicks(yRange, config.yAxis)
        let yLabelWidth = tuiTickLabelWidth(yTicks, config.yAxis)
        let names = ArrayList<String>()
        let colors = ArrayList<String>()
        for (item in series) {
            names.add(item.name)
            colors.add(item.color)
        }
        let legend = tuiLegendVisible(config, names.toArray())
        let frame = TuiFrame(config, yLabelWidth, legendVisible: legend)
        let canvas = TuiCanvas(Int64(config.width), Int64(config.height))
        frame.drawTitle(canvas)
        frame.drawLegend(canvas, names.toArray(), colors.toArray())
        let yScale = LinearScale(
            yRange[0], yRange[1],
            Float64(frame.plot.y), Float64(frame.plot.bottom())
        )
        let xScale = LinearScale(
            xRange[0], xRange[1],
            Float64(frame.plot.x), Float64(frame.plot.right())
        )
        frame.drawYAxis(canvas, yTicks, yScale)
        for (item in series) {
            for (point in item.points) {
                match (point.y) {
                    case Some(value) =>
                        let px = clampTuiColumn(
                            Int64(round(xScale.scale(point.x))), frame.plot
                        )
                        let py = clampTuiRow(
                            Int64(round(yScale.scale(value))), frame.plot
                        )
                        canvas.set(px, py, "o", item.color)
                    case None => ()
                }
            }
        }
        let xTicks = tuiTicks(xRange, config.xAxis)
        let xLabels = ArrayList<String>()
        for (tick in xTicks) {
            if (config.xAxis.axisType == "time") {
                xLabels.add(ChartTime.formatDays(tick))
            } else {
                xLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
            }
        }
        frame.drawXAxisNumeric(canvas, xTicks, xScale, xLabels.toArray())
        canvas.render()
    }
}
