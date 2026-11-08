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

/** LASSO 路径图的一个变量路径。 */
internal class LassoSeries {
    let name: String
    let points: Array<Array<Float64>>

    init(name: String, points: Array<Array<Float64>>) {
        this.name = name
        this.points = points
    }
}

/** M98 LASSO 路径图。 */
public class LassoPathChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "lasso-path")
        let root = ChartJson.of(data)
        let variables = root.stringArray("variables", default: Array<String>())
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<LassoSeries>()
        var seriesIndex = 0
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
            let raw = ArrayList<Array<Float64>>()
            var dataIndex = 0
            for (entry in dataItems) {
                let entryPath = "${seriesPath}.data[${dataIndex}]"
                if (!entry.kind.isObject) {
                    throw chartInvalidValue(entryPath, "期望 {x,y} 对象")
                }
                let pointJson = ChartJson.of(entry.asObject(), entryPath)
                let x = volcanoNumber(pointJson, "x", entryPath)
                let y = volcanoNumber(pointJson, "y", entryPath)
                raw.add([x, y])
                dataIndex++
            }
            let defaultName = if (seriesIndex < variables.size) {
                variables[seriesIndex]
            } else {
                (seriesIndex + 1).toString()
            }
            seriesList.add(LassoSeries(
                json.string("name", default: defaultName),
                sortLiftPoints(raw.toArray())
            ))
            seriesIndex++
        }
        let series = seriesList.toArray()

        var dataMinX = series[0].points[0][0]
        var dataMaxX = series[0].points[0][0]
        var dataMinY = minFloat(0.0, series[0].points[0][1])
        var dataMaxY = maxFloat(0.0, series[0].points[0][1])
        for (item in series) {
            for (point in item.points) {
                dataMinX = minFloat(dataMinX, point[0])
                dataMaxX = maxFloat(dataMaxX, point[0])
                dataMinY = minFloat(dataMinY, point[1])
                dataMaxY = maxFloat(dataMaxY, point[1])
            }
        }
        var xSpan = dataMaxX - dataMinX
        if (xSpan <= 0.0) {
            xSpan = 1.0
        }
        var ySpan = dataMaxY - dataMinY
        if (ySpan <= 0.0) {
            ySpan = 1.0
        }
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => dataMinX - xSpan * 0.03
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => dataMaxX + xSpan * 0.03
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMinY - ySpan * 0.05
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMaxY + ySpan * 0.05
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
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
        let legendVisible = config.legend.show && series.size > 1
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

        kit.line(
            frame.plot.x, yScale.scale(0.0), frame.plot.right(), yScale.scale(0.0),
            stroke: "#e0e0e0", strokeWidth: 1.0, className: "lasso-zero"
        )

        for (index in 0..series.size) {
            let item = series[index]
            let color = colors[index]
            let path = StringBuilder()
            for (position in 0..item.points.size) {
                let x = xScale.scale(item.points[position][0])
                let y = yScale.scale(item.points[position][1])
                if (position == 0) {
                    path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                } else {
                    path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                }
            }
            kit.path(
                path.toString(),
                fill: "none",
                stroke: color,
                strokeWidth: 1.5,
                className: "lasso-line"
            )
            for (point in item.points) {
                kit.circle(
                    xScale.scale(point[0]),
                    yScale.scale(point[1]),
                    2.5,
                    fill: color,
                    className: "lasso-point"
                )
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}
