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

/** 学习曲线的一个系列。 */
internal class LearningSeries {
    let name: String
    let points: Array<Array<Float64>>
    let std: Array<Float64>

    init(name: String, points: Array<Array<Float64>>, std: Array<Float64>) {
        this.name = name
        this.points = points
        this.std = std
    }
}

/** M97 学习曲线。 */
public class LearningCurveChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "learning-curve")
        let root = ChartJson.of(data)
        let metric = root.string("metric", default: "score")
        if (metric != "score" && metric != "loss") {
            throw chartInvalidValue("metric", "仅支持 score 或 loss")
        }
        let shade = root.bool("shade", default: false)

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<LearningSeries>()
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
            let stdValues = ArrayList<Float64>()
            match (json.value("std")) {
                case Some(entry) =>
                    if (!entry.kind.isArray) {
                        throw chartInvalidValue("${seriesPath}.std", "期望数组")
                    }
                    let stdItems = entry.asArray().getItems()
                    if (stdItems.size != raw.size) {
                        throw chartInvalidValue("${seriesPath}.std", "标准差长度必须与数据一致")
                    }
                    var stdIndex = 0
                    for (stdItem in stdItems) {
                        if (!(stdItem.kind.isInt || stdItem.kind.isDecimal)) {
                            throw chartInvalidValue(
                                "${seriesPath}.std[${stdIndex}]", "期望数字"
                            )
                        }
                        let value = jsonNumberValue(
                            stdItem, "${seriesPath}.std[${stdIndex}]"
                        )
                        if (value < 0.0) {
                            throw chartInvalidValue(
                                "${seriesPath}.std[${stdIndex}]", "标准差不能为负"
                            )
                        }
                        stdValues.add(value)
                        stdIndex++
                    }
                case None => ()
            }
            seriesList.add(LearningSeries(
                json.string("name", default: (seriesIndex + 1).toString()),
                sortLiftPoints(raw.toArray()),
                stdValues.toArray()
            ))
            seriesIndex++
        }
        let series = seriesList.toArray()

        var dataMinX = series[0].points[0][0]
        var dataMaxX = series[0].points[0][0]
        var dataMinY = series[0].points[0][1]
        var dataMaxY = series[0].points[0][1]
        for (item in series) {
            for (index in 0..item.points.size) {
                let x = item.points[index][0]
                let y = item.points[index][1]
                dataMinX = minFloat(dataMinX, x)
                dataMaxX = maxFloat(dataMaxX, x)
                dataMinY = minFloat(dataMinY, y)
                dataMaxY = maxFloat(dataMaxY, y)
                if (index < item.std.size) {
                    dataMinY = minFloat(dataMinY, y - item.std[index])
                    dataMaxY = maxFloat(dataMaxY, y + item.std[index])
                }
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

        for (index in 0..series.size) {
            let item = series[index]
            let color = colors[index]
            if (shade && item.std.size == item.points.size) {
                let band = StringBuilder()
                for (position in 0..item.points.size) {
                    let x = xScale.scale(item.points[position][0])
                    let y = yScale.scale(item.points[position][1] + item.std[position])
                    if (position == 0) {
                        band.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    } else {
                        band.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    }
                }
                var position = item.points.size - 1
                while (position >= 0) {
                    let x = xScale.scale(item.points[position][0])
                    let y = yScale.scale(item.points[position][1] - item.std[position])
                    band.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    position--
                }
                band.append(" Z")
                kit.path(
                    band.toString(),
                    fill: color,
                    className: "learning-band",
                    fillOpacity: 0.15
                )
            }
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
                strokeWidth: 2.0,
                className: "learning-line"
            )
            for (point in item.points) {
                kit.circle(
                    xScale.scale(point[0]),
                    yScale.scale(point[1]),
                    3.5,
                    fill: color,
                    className: "learning-point"
                )
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}
