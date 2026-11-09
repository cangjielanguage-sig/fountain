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

/** M5 折线图的 TUI 实现。 */
public class TuiLineChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(
            data, "line", defaultWidth: 80.0, defaultHeight: 24.0
        )
        let root = ChartJson.of(data)
        let series = tuiParsePointSeries(config, root.requiredArray("series"))
        let category = config.xAxis.axisType == "category"
        var labels = Array<String>()
        var xRange = [0.0, 1.0]
        if (category) {
            var count: Int64 = 1
            for (item in series) {
                count = tuiMaxInt64(count, item.points.size)
            }
            labels = tuiResolveLabels(config, count)
            for (item in series) {
                if (item.points.size != labels.size) {
                    throw chartInvalidValue("series.data", "数据长度必须与 xAxis.labels 一致")
                }
            }
        } else {
            xRange = tuiValueRange(tuiPointXValues(series), config.xAxis, false)
        }

        let yValues = tuiPointYValues(series)
        if (yValues.isEmpty()) {
            throw chartInvalidValue("series.data", "至少需要一个有效 y 值")
        }
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
        frame.drawYAxis(canvas, yTicks, yScale)

        if (category) {
            let categoryBand = BandScale(
                Float64(frame.plot.x), Float64(frame.plot.right()), labels.size
            )
            drawLines(canvas, frame, series, None, Some(categoryBand), yScale)
            frame.drawXAxisCategory(canvas, labels, categoryBand)
        } else {
            let xScale = LinearScale(
                xRange[0], xRange[1],
                Float64(frame.plot.x), Float64(frame.plot.right())
            )
            drawLines(canvas, frame, series, Some(xScale), None, yScale)
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
        }
        canvas.render()
    }

    private func drawLines(
        canvas: TuiCanvas,
        frame: TuiFrame,
        series: Array<TuiPointSeries>,
        xScale: Option<LinearScale>,
        band: Option<BandScale>,
        yScale: LinearScale
    ): Unit {
        for (item in series) {
            var previousX: Int64 = 0
            var previousY: Int64 = 0
            var hasPrevious = false
            for (point in item.points) {
                match (point.y) {
                    case Some(value) =>
                        var x = 0.0
                        match (band) {
                            case Some(scale) => x = scale.center(Int64(round(point.x)))
                            case None =>
                                match (xScale) {
                                    case Some(scale) => x = scale.scale(point.x)
                                    case None => ()
                                }
                        }
                        let px = clampTuiColumn(Int64(round(x)), frame.plot)
                        let py = clampTuiRow(
                            Int64(round(yScale.scale(value))), frame.plot
                        )
                        if (hasPrevious) {
                            canvas.drawLine(
                                previousX, previousY, px, py, "*", item.color
                            )
                        }
                        canvas.set(px, py, "o", item.color)
                        previousX = px
                        previousY = py
                        hasPrevious = true
                    case None => hasPrevious = false
                }
            }
        }
    }
}

internal func clampTuiColumn(column: Int64, plot: TuiRect): Int64 {
    if (column < plot.x) {
        plot.x
    } else if (column > plot.right()) {
        plot.right()
    } else {
        column
    }
}
