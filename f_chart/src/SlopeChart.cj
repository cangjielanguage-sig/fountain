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

/** 斜率图的一个系列。 */
internal class SlopeSeries {
    let name: String
    let values: Array<Float64>
    let color: Option<String>

    init(name: String, values: Array<Float64>, color: Option<String>) {
        this.name = name
        this.values = values
        this.color = color
    }
}

/** M78 斜率图。 */
public class SlopeChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "slope")
        let root = ChartJson.of(data)
        let labels = if (config.xAxis.labels.isEmpty()) {
            ["前", "后"]
        } else {
            config.xAxis.labels
        }
        if (labels.size != 2) {
            throw chartInvalidValue("xAxis.labels", "斜率图必须恰好 2 个时间点")
        }

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<SlopeSeries>()
        var seriesIndex = 0
        for (item in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let dataArray = json.requiredArray("data")
            let dataItems = dataArray.getItems()
            if (dataItems.size != 2) {
                throw chartInvalidValue("${seriesPath}.data", "斜率图每个系列必须恰好 2 个数值")
            }
            let values = ArrayList<Float64>()
            var dataIndex = 0
            for (value in dataItems) {
                if (!(value.kind.isInt || value.kind.isDecimal)) {
                    throw chartInvalidValue(
                        "${seriesPath}.data[${dataIndex}]", "期望数字"
                    )
                }
                values.add(jsonNumberValue(value, "${seriesPath}.data[${dataIndex}]"))
                dataIndex++
            }
            seriesList.add(SlopeSeries(
                json.string("name", default: (seriesIndex + 1).toString()),
                values.toArray(),
                json.string("color")
            ))
            seriesIndex++
        }

        let seriesArrayValue = seriesList.toArray()
        var dataMin = seriesArrayValue[0].values[0]
        var dataMax = dataMin
        for (item in seriesArrayValue) {
            for (value in item.values) {
                dataMin = minFloat(dataMin, value)
                dataMax = maxFloat(dataMax, value)
            }
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.05
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.05
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }

        var maxLabelWidth = 0.0
        for (item in seriesArrayValue) {
            maxLabelWidth = maxFloat(
                maxLabelWidth, chartTextWidth(item.name, config.theme.fontSize)
            )
        }
        var maxYTickWidth = 0.0
        for (tick in yTicks) {
            maxYTickWidth = maxFloat(
                maxYTickWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let legendVisible = config.legend.show && seriesArrayValue.size > 1
        let frame = ChartFrame(
            config, legendVisible, maxYTickWidth + 12.0, config.theme.fontSize + 12.0,
            rightLabelWidth: maxLabelWidth + 16.0
        )
        let band = BandScale(frame.plot.x, frame.plot.right(), 2)
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
        for (index in 0..seriesArrayValue.size) {
            names.add(seriesArrayValue[index].name)
            colors.add(match (seriesArrayValue[index].color) {
                case Some(color) => color
                case None => config.theme.colorAt(index)
            })
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        let leftX = band.center(0)
        let rightX = band.center(1)
        for (index in 0..seriesArrayValue.size) {
            let item = seriesArrayValue[index]
            let color = colors[index]
            let startY = yScale.scale(item.values[0])
            let endY = yScale.scale(item.values[1])
            kit.line(
                leftX, startY, rightX, endY,
                stroke: color, strokeWidth: 2.0, className: "slope-line"
            )
            kit.circle(leftX, startY, 4.0, fill: color, className: "slope-point")
            kit.circle(rightX, endY, 4.0, fill: color, className: "slope-point")
            kit.text(
                rightX + 8.0,
                endY + config.theme.fontSize / 3.0,
                item.name,
                size: config.theme.fontSize,
                color: color,
                className: "slope-label"
            )
        }
        frame.drawXAxis(kit, labels, band)
        builder.toSvgString()
    }
}
