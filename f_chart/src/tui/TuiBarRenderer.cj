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

internal class TuiBarSeries {
    let name: String
    let values: Array<?Float64>
    let color: String
    let stack: String

    init(name: String, values: Array<?Float64>, color: String, stack: String) {
        this.name = name
        this.values = values
        this.color = color
        this.stack = stack
    }
}

/** 柱状图族的 TUI 渲染器。 */
internal class TuiBarRenderer {
    static func render(data: JsonObject, expectedType: String, mode: BarMode): String {
        let config = ChartConfig.parse(
            data, expectedType, defaultWidth: 80.0, defaultHeight: 24.0
        )
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let items = seriesArray.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<TuiBarSeries>()
        var index = 0
        for (item in items) {
            let itemPath = "series[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望系列对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let values = json.numberOrNullArray("data")
            if (values.isEmpty()) {
                throw chartInvalidValue("${itemPath}.data", "数据不能为空")
            }
            series.add(TuiBarSeries(
                json.string("name", default: ""),
                values,
                tuiSeriesColor(config, index, json.string("color", default: "")),
                json.string("stack", default: "")
            ))
            index++
        }

        var count = series[0].values.size
        for (item in series) {
            count = tuiMaxInt64(count, item.values.size)
        }
        let labels = tuiResolveLabels(config, count)
        for (item in series) {
            if (item.values.size != labels.size) {
                throw chartInvalidValue("series.data", "数据长度必须与 xAxis.labels 一致")
            }
        }

        let values = ArrayList<Float64>()
        for (item in series) {
            for (value in item.values) {
                match (value) {
                    case Some(number) => values.add(number)
                    case None => ()
                }
            }
        }
        var range: Array<Float64>
        match (mode) {
            case PercentStacked => range = [0.0, 100.0]
            case _ => range = tuiValueRange(values.toArray(), config.yAxis, true)
        }
        let ticks = tuiTicks(range, config.yAxis)
        let labelWidth = tuiTickLabelWidth(ticks, config.yAxis)
        let names = ArrayList<String>()
        let colors = ArrayList<String>()
        for (item in series) {
            names.add(item.name)
            colors.add(item.color)
        }
        let legend = tuiLegendVisible(config, names.toArray())
        let frame = TuiFrame(config, labelWidth, legendVisible: legend)
        let canvas = TuiCanvas(Int64(config.width), Int64(config.height))
        frame.drawTitle(canvas)
        frame.drawLegend(canvas, names.toArray(), colors.toArray())
        let scale = LinearScale(
            range[0], range[1],
            Float64(frame.plot.y), Float64(frame.plot.bottom())
        )
        frame.drawYAxis(canvas, ticks, scale)
        let band = BandScale(
            Float64(frame.plot.x), Float64(frame.plot.right()), labels.size
        )
        let baselineValue = if (range[0] > 0.0) {
            range[0]
        } else if (range[1] < 0.0) {
            range[1]
        } else {
            0.0
        }
        let baselineRow = clampTuiRow(
            Int64(round(scale.scale(baselineValue))), frame.plot
        )
        match (mode) {
            case Simple | Grouped => drawSideBySide(
                canvas, frame, band, scale, series, baselineRow, mode
            )
            case Stacked | PercentStacked => drawStacked(
                canvas, frame, band, scale, series, mode
            )
        }
        frame.drawXAxisCategory(canvas, labels, band)
        canvas.render()
    }

    private static func drawSideBySide(
        canvas: TuiCanvas,
        frame: TuiFrame,
        band: BandScale,
        scale: LinearScale,
        series: ArrayList<TuiBarSeries>,
        baselineRow: Int64,
        mode: BarMode
    ): Unit {
        var slotCount = series.size
        match (mode) {
            case Simple =>
                if (series.size == 1) {
                    slotCount = 1
                }
            case _ => ()
        }
        let slotWidth = band.bandWidth / Float64(tuiMaxInt64(slotCount, 1))
        let barWidth = tuiMaxInt64(Int64(floor(slotWidth * 0.6)), 1)
        let count = series[0].values.size
        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            for (category in 0..count) {
                match (item.values[category]) {
                    case Some(value) =>
                        let slotStart = band.bandStart(category) +
                            Float64(seriesIndex) * slotWidth
                        let x = Int64(round(slotStart + (slotWidth - Float64(barWidth)) / 2.0))
                        let row = clampTuiRow(
                            Int64(round(scale.scale(value))), frame.plot
                        )
                        tuiFillColumn(
                            canvas, x, barWidth, baselineRow, row, item.color,
                            symbol: tuiSeriesSymbol(seriesIndex)
                        )
                    case None => ()
                }
            }
        }
    }

    private static func drawStacked(
        canvas: TuiCanvas,
        frame: TuiFrame,
        band: BandScale,
        scale: LinearScale,
        series: ArrayList<TuiBarSeries>,
        mode: BarMode
    ): Unit {
        let barWidth = tuiMaxInt64(Int64(floor(band.bandWidth * 0.6)), 1)
        let count = series[0].values.size
        for (category in 0..count) {
            var positive = 0.0
            var negative = 0.0
            if (isPercent(mode)) {
                for (item in series) {
                    match (item.values[category]) {
                        case Some(value) =>
                            if (value > 0.0) {
                                positive += value
                            }
                        case None => ()
                    }
                }
            }
            var positiveBase = 0.0
            var negativeBase = 0.0
            for (seriesIndex in 0..series.size) {
                let item = series[seriesIndex]
                match (item.values[category]) {
                    case Some(value) =>
                        var from = 0.0
                        var to = 0.0
                        if (isPercent(mode)) {
                            if (value <= 0.0 || positive <= 0.0) {
                                continue
                            }
                            from = positiveBase
                            to = positiveBase + value / positive * 100.0
                            positiveBase = to
                        } else if (value >= 0.0) {
                            from = positiveBase
                            to = positiveBase + value
                            positiveBase = to
                        } else {
                            from = negativeBase
                            to = negativeBase + value
                            negativeBase = to
                        }
                        let x = Int64(round(band.center(category))) - barWidth / 2
                        let fromRow = clampTuiRow(
                            Int64(round(scale.scale(from))), frame.plot
                        )
                        let toRow = clampTuiRow(
                            Int64(round(scale.scale(to))), frame.plot
                        )
                        tuiFillColumn(
                            canvas, x, barWidth, fromRow, toRow, item.color,
                            symbol: tuiSeriesSymbol(seriesIndex)
                        )
                    case None => ()
                }
            }
        }
    }

    private static func isPercent(mode: BarMode): Bool {
        match (mode) {
            case PercentStacked => true
            case _ => false
        }
    }
}

internal func clampTuiRow(row: Int64, plot: TuiRect): Int64 {
    if (row < plot.y) {
        plot.y
    } else if (row > plot.bottom()) {
        plot.bottom()
    } else {
        row
    }
}
