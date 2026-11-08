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
import std.math.*
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 柱状图的一个系列。 */
internal class BarSeries {
    let name: String
    let values: Array<?Float64>
    let color: ?String
    let barWidth: ?Float64

    init(name: String, values: Array<?Float64>, color: ?String, barWidth: ?Float64) {
        this.name = name
        this.values = values
        this.color = color
        this.barWidth = barWidth
    }
}

/** 柱状渲染模式。 */
internal enum BarMode {
    | Simple
    | Grouped
    | Stacked
}

/**
 * 柱状家族共享渲染器：解析、布局、轴、图例与柱图元。
 *
 * M2 先支持 `Simple` 与 `Grouped`；M3/M4 在同一处扩展堆叠模式。
 */
internal class BarRenderer {
    static func render(data: JsonObject, expectedType: String, mode: BarMode): String {
        let config = ChartConfig.parse(data, expectedType)
        let root = ChartJson.of(data)
        let series = parseSeries(root.requiredArray("series"))
        if (series.isEmpty()) {
            throw chartMissingField("series")
        }
        let labels = resolveLabels(config.xAxis.labels, series)
        validateLengths(series, labels)
        let range = match (mode) {
            case Stacked => resolveStackedRange(config.yAxis, series, labels)
            case _ => resolveRange(config.yAxis, series)
        }
        let ticks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(range[0], range[1], config.yAxis.tickCount)
        }

        let legendVisible = config.legend.show && !(series.size == 1 && series[0].name.isEmpty())
        var maxLabelWidth = 0.0
        for (tick in ticks) {
            let width = chartTextWidth(
                chartFormatTick(tick, config.yAxis.labelFormat),
                config.theme.fontSize
            )
            if (width > maxLabelWidth) {
                maxLabelWidth = width
            }
        }
        let yLabelWidth = maxLabelWidth + 12.0
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, yLabelWidth, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), labels.size)
        let scale = LinearScale(range[0], range[1], frame.plot.y, frame.plot.bottom())

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let names = ArrayList<String>()
        let colors = ArrayList<String>()
        for (index in 0..series.size) {
            names.add(series[index].name)
            colors.add(match (series[index].color) {
                case Some(color) => color
                case None => config.theme.colorAt(index)
            })
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, ticks, scale)

        let baselineValue = if (range[0] > 0.0) {
            range[0]
        } else if (range[1] < 0.0) {
            range[1]
        } else {
            0.0
        }
        let baseline = scale.scale(baselineValue)
        let seriesCount = maxInt64(series.size, 1)
        match (mode) {
            case Stacked =>
                let stackedWidth = match (series[0].barWidth) {
                    case Some(value) => value
                    case None => band.bandWidth * 0.6
                }
                let barWidth = minFloat(stackedWidth, band.bandWidth * 0.95)
                for (index in 0..labels.size) {
                    let x = stackedBarX(band, index, barWidth)
                    var positive = 0.0
                    var negative = 0.0
                    for (seriesIndex in 0..series.size) {
                        match (series[seriesIndex].values[index]) {
                            case Some(value) =>
                                let color = match (series[seriesIndex].color) {
                                    case Some(itemColor) => itemColor
                                    case None => config.theme.colorAt(seriesIndex)
                                }
                                if (value >= 0.0) {
                                    let from = scale.scale(positive)
                                    let to = scale.scale(positive + value)
                                    kit.rect(
                                        x, minFloat(from, to), barWidth, abs(to - from),
                                        fill: color, className: "bar"
                                    )
                                    positive += value
                                } else {
                                    let from = scale.scale(negative)
                                    let to = scale.scale(negative + value)
                                    kit.rect(
                                        x, minFloat(from, to), barWidth, abs(to - from),
                                        fill: color, className: "bar bar-negative"
                                    )
                                    negative += value
                                }
                            case None => ()
                        }
                    }
                }
            case _ =>
                let slotWidth = match (mode) {
                    case Simple =>
                        if (series.size == 1) {
                            band.bandWidth
                        } else {
                            band.bandWidth / Float64(seriesCount)
                        }
                    case _ => band.bandWidth / Float64(seriesCount)
                }
                for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            let requestedWidth = match (item.barWidth) {
                case Some(value) => value
                case None => slotWidth * 0.6
            }
            let barWidth = minFloat(requestedWidth, slotWidth * 0.95)
            for (index in 0..labels.size) {
                match (item.values[index]) {
                    case Some(value) =>
                        let x = groupedBarX(band, index, seriesIndex, seriesCount, barWidth)
                        let valueY = scale.scale(value)
                        let top = minFloat(valueY, baseline)
                        let height = abs(valueY - baseline)
                        let className = if (value < 0.0) {
                            "bar bar-negative"
                        } else {
                            "bar"
                        }
                        kit.rect(x, top, barWidth, height, fill: color, className: className)
                    case None => ()
                }
            }
        }
        }

        frame.drawXAxis(kit, labels, band)
        builder.toSvgString()
    }

    private static func parseSeries(items: JsonArray): Array<BarSeries> {
        let series = ArrayList<BarSeries>()
        var index = 0
        for (item in items.getItems()) {
            let path = "series[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let data = json.requiredArray("data")
            let values = parseValues(data, "${path}.data")
            let color = json.string("color")
            let barWidth = json.number("barWidth")
            match (barWidth) {
                case Some(value) =>
                    if (value <= 0.0) {
                        throw chartInvalidValue("${path}.barWidth", "柱宽必须大于 0")
                    }
                case None => ()
            }
            series.add(BarSeries(name, values, color, barWidth))
            index++
        }
        series.toArray()
    }

    private static func parseValues(items: JsonArray, path: String): Array<?Float64> {
        let values = ArrayList<?Float64>()
        var index = 0
        for (item in items.getItems()) {
            let itemPath = "${path}[${index}]"
            if (item.kind.isNull) {
                values.add(None<Float64>)
            } else {
                values.add(Some(jsonNumberValue(item, itemPath)))
            }
            index++
        }
        values.toArray()
    }

    private static func resolveLabels(labels: Array<String>, series: Array<BarSeries>): Array<String> {
        if (!labels.isEmpty()) {
            return labels
        }
        var longest = 0
        for (item in series) {
            if (item.values.size > longest) {
                longest = item.values.size
            }
        }
        let generated = ArrayList<String>()
        for (index in 0..longest) {
            generated.add((index + 1).toString())
        }
        generated.toArray()
    }

    private static func validateLengths(series: Array<BarSeries>, labels: Array<String>): Unit {
        for (index in 0..series.size) {
            if (series[index].values.size != labels.size) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${series[index].values.size} 与 xAxis.labels 长度 ${labels.size} 不一致"
                )
            }
        }
    }

    private static func resolveRange(axis: ChartAxis, series: Array<BarSeries>): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        for (item in series) {
            for (value in item.values) {
                match (value) {
                    case Some(number) =>
                        if (!hasData) {
                            dataMin = number
                            dataMax = number
                            hasData = true
                        } else {
                            dataMin = minFloat(dataMin, number)
                            dataMax = maxFloat(dataMax, number)
                        }
                    case None => ()
                }
            }
        }
        if (!hasData) {
            dataMin = 0.0
            dataMax = 1.0
        }
        applyAxisRange(axis, dataMin, dataMax)
    }

    private static func resolveStackedRange(
        axis: ChartAxis,
        series: Array<BarSeries>,
        labels: Array<String>
    ): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        for (index in 0..labels.size) {
            var positive = 0.0
            var negative = 0.0
            for (item in series) {
                match (item.values[index]) {
                    case Some(number) =>
                        hasData = true
                        if (number >= 0.0) {
                            positive += number
                        } else {
                            negative += number
                        }
                    case None => ()
                }
            }
            if (positive > dataMax) {
                dataMax = positive
            }
            if (negative < dataMin) {
                dataMin = negative
            }
        }
        if (!hasData) {
            dataMin = 0.0
            dataMax = 1.0
        }
        applyAxisRange(axis, dataMin, dataMax)
    }

    private static func applyAxisRange(
        axis: ChartAxis,
        dataMin: Float64,
        dataMax: Float64
    ): Array<Float64> {
        var minimum = match (axis.min) {
            case Some(value) => value
            case None =>
                if (dataMin < 0.0) {
                    dataMin * 1.05
                } else {
                    0.0
                }
        }
        var maximum = match (axis.max) {
            case Some(value) => value
            case None =>
                if (dataMax > 0.0) {
                    dataMax * 1.05
                } else {
                    0.0
                }
        }
        if (maximum <= minimum) {
            if (axis.max.isSome() || axis.min.isSome()) {
                throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
            }
            maximum = minimum + 1.0
        }
        [minimum, maximum]
    }
}

/** 分组柱在类目槽内的 x 坐标。 */
internal func groupedBarX(
    band: BandScale,
    categoryIndex: Int64,
    seriesIndex: Int64,
    seriesCount: Int64,
    barWidth: Float64
): Float64 {
    let count = maxInt64(seriesCount, 1)
    let slot = band.bandWidth / Float64(count)
    band.bandStart(categoryIndex) + Float64(seriesIndex) * slot + (slot - barWidth) / 2.0
}

/** 堆叠柱的 x 坐标：同一类目的所有段共用。 */
internal func stackedBarX(band: BandScale, categoryIndex: Int64, barWidth: Float64): Float64 {
    band.center(categoryIndex) - barWidth / 2.0
}

internal func minFloat(left: Float64, right: Float64): Float64 {
    if (left < right) {
        left
    } else {
        right
    }
}

internal func maxFloat(left: Float64, right: Float64): Float64 {
    if (left > right) {
        left
    } else {
        right
    }
}

internal func maxInt64(left: Int64, right: Int64): Int64 {
    if (left > right) {
        left
    } else {
        right
    }
}
