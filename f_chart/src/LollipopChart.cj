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

/** 棒棒糖图的一个系列。 */
internal class LollipopSeries {
    let name: String
    let values: Array<Option<Float64>>
    let color: Option<String>
    let symbolSize: Float64

    init(
        name: String,
        values: Array<Option<Float64>>,
        color: Option<String>,
        symbolSize: Float64
    ) {
        this.name = name
        this.values = values
        this.color = color
        this.symbolSize = symbolSize
    }
}

/** M79 棒棒糖图。 */
public class LollipopChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "lollipop")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<LollipopSeries>()
        var seriesIndex = 0
        for (item in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let dataArray = json.requiredArray("data")
            let values = ArrayList<Option<Float64>>()
            var dataIndex = 0
            for (value in dataArray.getItems()) {
                let valuePath = "${seriesPath}.data[${dataIndex}]"
                if (value.kind.isNull) {
                    values.add(None<Float64>)
                } else {
                    values.add(Some(jsonNumberValue(value, valuePath)))
                }
                dataIndex++
            }
            let symbolSize = json.number("symbolSize", default: 8.0)
            if (symbolSize <= 0.0) {
                throw chartInvalidValue("${seriesPath}.symbolSize", "点大小必须大于 0")
            }
            seriesList.add(LollipopSeries(
                json.string("name", default: ""),
                values.toArray(),
                json.string("color"),
                symbolSize
            ))
            seriesIndex++
        }
        let series = seriesList.toArray()

        let labels = ArrayList<String>()
        if (!config.xAxis.labels.isEmpty()) {
            for (label in config.xAxis.labels) {
                labels.add(label)
            }
        } else {
            var longest = 0
            for (item in series) {
                longest = maxInt64(longest, item.values.size)
            }
            for (index in 0..longest) {
                labels.add((index + 1).toString())
            }
        }
        for (item in series) {
            if (item.values.size != labels.size) {
                throw chartInvalidValue(
                    "xAxis.labels",
                    "标签长度 ${labels.size} 与数据长度 ${item.values.size} 不一致"
                )
            }
        }

        var dataMin = 0.0
        var dataMax = 0.0
        for (item in series) {
            for (value in item.values) {
                match (value) {
                    case Some(number) =>
                        dataMin = minFloat(dataMin, number)
                        dataMax = maxFloat(dataMax, number)
                    case None => ()
                }
            }
        }
        var yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMin
        }
        var yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMax
        }
        if (yMax < yMin) {
            throw chartInvalidValue("yAxis.max", "最大值必须不小于最小值")
        }
        if (yMax == yMin) {
            yMin -= 1.0
            yMax += 1.0
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in yTicks) {
            tickLabels.add(chartFormatTick(tick, config.yAxis.labelFormat))
        }

        let legendVisible = config.legend.show && !(series.size == 1 && series[0].name.isEmpty())
        var maxYLabelWidth = 0.0
        for (label in tickLabels) {
            maxYLabelWidth = maxFloat(
                maxYLabelWidth, chartTextWidth(label, config.theme.fontSize)
            )
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), labels.size)
        let yScale = LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())

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
        frame.drawYAxis(kit, yTicks, yScale)

        let baseline = yScale.scale(0.0)
        let slot = band.bandWidth / Float64(maxInt64(series.size, 1))
        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = colors[seriesIndex]
            let radius = item.symbolSize / 2.0
            for (index in 0..labels.size) {
                match (item.values[index]) {
                    case Some(value) =>
                        let x = band.bandStart(index) + Float64(seriesIndex) * slot + slot / 2.0
                        let y = yScale.scale(value)
                        kit.line(
                            x, baseline, x, y,
                            stroke: color, strokeWidth: 2.0, className: "lollipop-stem"
                        )
                        kit.circle(x, y, radius, fill: color, className: "lollipop-head")
                    case None => ()
                }
            }
        }
        frame.drawXAxis(kit, labels.toArray(), band)
        builder.toSvgString()
    }
}
