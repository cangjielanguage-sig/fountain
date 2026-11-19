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
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

/** ECDF 的一个系列。 */
internal class EcdfSeries {
    let name: String
    let values: Array<Float64>

    init(name: String, values: Array<Float64>) {
        this.name = name
        this.values = values
    }
}

/** M90 累积频率图。 */
public class EcdfChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "ecdf")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<EcdfSeries>()
        var seriesIndex = 0
        var dataMin = 0.0
        var dataMax = 0.0
        var hasValue = false
        for (item in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let dataArray = json.requiredArray("data")
            let dataItems = dataArray.getItems()
            if (dataItems.isEmpty()) {
                throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
            }
            let values = ArrayList<Float64>()
            var dataIndex = 0
            for (value in dataItems) {
                if (!(value.kind.isInt || value.kind.isDecimal)) {
                    throw chartInvalidValue(
                        "${seriesPath}.data[${dataIndex}]", "期望数字"
                    )
                }
                let number = jsonNumberValue(value, "${seriesPath}.data[${dataIndex}]")
                values.add(number)
                if (!hasValue) {
                    dataMin = number
                    dataMax = number
                    hasValue = true
                } else {
                    dataMin = minFloat(dataMin, number)
                    dataMax = maxFloat(dataMax, number)
                }
                dataIndex++
            }
            seriesList.add(EcdfSeries(
                json.string("name", default: (seriesIndex + 1).toString()),
                values.toArray()
            ))
            seriesIndex++
        }
        let series = seriesList.toArray()

        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.02
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.02
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => 1.0
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xMin, xMax, config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            maxYLabelWidth = maxFloat(
                maxYLabelWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let legendVisible = config.legend.show && !(series.size == 1 && series[0].name.isEmpty())
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let xScale = LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())
        let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)

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
            colors.add(config.theme.colorAt(index))
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        for (index in 0..series.size) {
            let points = ecdfPoints(series[index].values)
            if (points.isEmpty()) {
                continue
            }
            let path = StringBuilder()
            let firstY = yScale.scale(points[0][1])
            path.append(
                "M ${formatSvgNumber(xScale.scale(points[0][0]))} " +
                    "${formatSvgNumber(yScale.scale(yMin))}"
            )
            path.append(" V ${formatSvgNumber(firstY)}")
            for (position in 0..points.size) {
                let x = xScale.scale(points[position][0])
                let y = yScale.scale(points[position][1])
                path.append(" H ${formatSvgNumber(x)}")
                if (position + 1 < points.size) {
                    let nextY = yScale.scale(points[position + 1][1])
                    path.append(" V ${formatSvgNumber(nextY)}")
                }
            }
            kit.path(
                path.toString(),
                fill: "none",
                stroke: colors[index],
                strokeWidth: 2.0,
                className: "ecdf-line"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}

/** 排序后返回 `[值, 累计频率]` 序列。 */
internal func ecdfPoints(values: Array<Float64>): Array<Array<Float64>> {
    let sorted = sortRaincloud(values)
    let points = ArrayList<Array<Float64>>()
    let count = sorted.size
    if (count == 0) {
        return points.toArray()
    }
    for (index in 0..count) {
        points.add([sorted[index], Float64(index + 1) / Float64(count)])
    }
    points.toArray()
}
