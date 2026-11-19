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

internal class DotSeries {
    let name: String
    let values: Array<?Float64>
    let color: ?String
    let symbolSize: Float64

    init(name: String, values: Array<?Float64>, color: ?String, symbolSize: Float64) {
        this.name = name
        this.values = values
        this.color = color
        this.symbolSize = symbolSize
    }
}

/** M12 点图 / 克利夫兰点图。 */
public class DotChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "dot")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = parseSeries(seriesArray)
        let labels = if (!config.yAxis.labels.isEmpty()) {
            config.yAxis.labels
        } else {
            Array<String>()
        }
        let resolvedLabels = resolveLabels(labels, series)
        validateLengths(series, resolvedLabels)
        let range = resolveRange(config.xAxis, series)
        let ticks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(range[0], range[1], config.xAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in ticks) {
            tickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show && !(series.size == 1 && series[0].name.isEmpty())
        var maxLabelWidth = 0.0
        for (label in resolvedLabels) {
            let width = chartTextWidth(label, config.theme.fontSize)
            if (width > maxLabelWidth) {
                maxLabelWidth = width
            }
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.y, frame.plot.bottom(), resolvedLabels.size)
        let xScale = LinearScale(range[0], range[1], frame.plot.right(), frame.plot.x)

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

        for (tick in ticks) {
            let x = xScale.scale(tick)
            kit.line(
                x, frame.plot.y, x, frame.plot.bottom(),
                stroke: config.theme.gridColor, strokeWidth: 1.0, className: "grid"
            )
        }

        let baseline = xScale.scale(0.0)
        let slot = band.bandWidth / Float64(maxInt64(series.size, 1))
        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            for (index in 0..resolvedLabels.size) {
                match (item.values[index]) {
                    case Some(value) =>
                        let valueX = xScale.scale(value)
                        let y = band.bandStart(index) + Float64(seriesIndex) * slot + slot / 2.0
                        kit.line(
                            baseline, y, valueX, y,
                            stroke: color, strokeWidth: 2.0, className: "stem"
                        )
                        kit.circle(
                            valueX, y, item.symbolSize / 2.0,
                            fill: color, className: "dot"
                        )
                    case None => ()
                }
            }
        }

        for (index in 0..resolvedLabels.size) {
            kit.text(
                frame.plot.x - 8.0, band.center(index), resolvedLabels[index],
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "category-label"
            )
        }
        frame.drawXAxisNumeric(kit, ticks, xScale, tickLabels.toArray())
        builder.toSvgString()
    }

    private func parseSeries(items: JsonArray): Array<DotSeries> {
        let series = ArrayList<DotSeries>()
        var index = 0
        for (item in items.getItems()) {
            let path = "series[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let values = ArrayList<?Float64>()
            let data = json.requiredArray("data")
            var dataIndex = 0
            for (value in data.getItems()) {
                let valuePath = "${path}.data[${dataIndex}]"
                if (value.kind.isNull) {
                    values.add(None<Float64>)
                } else {
                    values.add(Some(jsonNumberValue(value, valuePath)))
                }
                dataIndex++
            }
            let symbolSize = json.number("symbolSize", default: 8.0)
            if (symbolSize <= 0.0) {
                throw chartInvalidValue("${path}.symbolSize", "点大小必须大于 0")
            }
            series.add(DotSeries(
                json.string("name", default: ""),
                values.toArray(),
                json.string("color"),
                symbolSize
            ))
            index++
        }
        series.toArray()
    }

    private func resolveLabels(labels: Array<String>, series: Array<DotSeries>): Array<String> {
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

    private func validateLengths(series: Array<DotSeries>, labels: Array<String>): Unit {
        for (index in 0..series.size) {
            if (series[index].values.size != labels.size) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${series[index].values.size} 与 yAxis.labels 长度 ${labels.size} 不一致"
                )
            }
        }
    }

    private func resolveRange(axis: ChartAxis, series: Array<DotSeries>): Array<Float64> {
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
                throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
            }
            maximum = minimum + 1.0
        }
        [minimum, maximum]
    }
}
