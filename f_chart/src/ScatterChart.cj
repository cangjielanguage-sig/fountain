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

internal class ScatterPoint {
    let x: Float64
    let y: Float64

    init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

internal class ScatterSeries {
    let name: String
    let points: Array<ScatterPoint>
    let color: ?String
    let symbol: String
    let symbolSize: Float64

    init(
        name: String,
        points: Array<ScatterPoint>,
        color: ?String,
        symbol: String,
        symbolSize: Float64
    ) {
        this.name = name
        this.points = points
        this.color = color
        this.symbol = symbol
        this.symbolSize = symbolSize
    }
}

/** M6 散点图：两个连续变量的关系。 */
public class ScatterChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "scatter")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<ScatterSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let points = parsePoints(
                json.requiredArray("data"),
                "${path}.data",
                config.xAxis.axisType
            )
            let color = json.string("color")
            let symbol = json.string("symbol", default: "circle")
            let symbolSize = json.number("symbolSize", default: 6.0)
            if (symbolSize <= 0.0) {
                throw chartInvalidValue("${path}.symbolSize", "点大小必须大于 0")
            }
            series.add(ScatterSeries(name, points, color, symbol, symbolSize))
            seriesIndex++
        }

        let xRange = resolveXRange(config.xAxis, series)
        let yRange = resolveYRange(config.yAxis, series)
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }
        let xLabels = ArrayList<String>()
        for (tick in xTicks) {
            xLabels.add(if (config.xAxis.axisType == "time") {
                ChartTime.formatDays(tick)
            } else {
                chartFormatTick(tick, config.xAxis.labelFormat)
            })
        }

        let legendVisible = config.legend.show && !(series.size == 1 && series[0].name.isEmpty())
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            let width = chartTextWidth(
                chartFormatTick(tick, config.yAxis.labelFormat),
                config.theme.fontSize
            )
            if (width > maxYLabelWidth) {
                maxYLabelWidth = width
            }
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())

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

        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            for (point in item.points) {
                let cx = xScale.scale(point.x)
                let cy = yScale.scale(point.y)
                match (item.symbol) {
                    case "square" => kit.square(cx, cy, item.symbolSize, fill: color, className: "symbol")
                    case "diamond" => kit.diamond(cx, cy, item.symbolSize, fill: color, className: "symbol")
                    case "none" => ()
                    case _ => kit.circle(cx, cy, item.symbolSize / 2.0, fill: color, className: "symbol")
                }
            }
        }

        frame.drawXAxisNumeric(kit, xTicks, xScale, xLabels.toArray())
        builder.toSvgString()
    }

    private func parsePoints(
        items: JsonArray,
        path: String,
        axisType: String
    ): Array<ScatterPoint> {
        let points = ArrayList<ScatterPoint>()
        var index = 0
        for (item in items.getItems()) {
            let itemPath = "${path}[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let xValue = json.required("x")
            let x = if (axisType == "time") {
                if (xValue.kind.isString) {
                    ChartTime.parseDays(xValue.asString().value, "${itemPath}.x")
                } else {
                    jsonNumberValue(xValue, "${itemPath}.x")
                }
            } else {
                jsonNumberValue(xValue, "${itemPath}.x")
            }
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            points.add(ScatterPoint(x, y))
            index++
        }
        points.toArray()
    }

    private func resolveXRange(axis: ChartAxis, series: ArrayList<ScatterSeries>): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        for (item in series) {
            for (point in item.points) {
                if (!hasData) {
                    dataMin = point.x
                    dataMax = point.x
                    hasData = true
                } else {
                    dataMin = minFloat(dataMin, point.x)
                    dataMax = maxFloat(dataMax, point.x)
                }
            }
        }
        if (!hasData) {
            dataMin = 0.0
            dataMax = 1.0
        }
        lineRange(dataMin, dataMax, axis.min, axis.max, "xAxis.min")
    }

    private func resolveYRange(axis: ChartAxis, series: ArrayList<ScatterSeries>): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        for (item in series) {
            for (point in item.points) {
                if (!hasData) {
                    dataMin = point.y
                    dataMax = point.y
                    hasData = true
                } else {
                    dataMin = minFloat(dataMin, point.y)
                    dataMax = maxFloat(dataMax, point.y)
                }
            }
        }
        if (!hasData) {
            dataMin = 0.0
            dataMax = 1.0
        }
        lineRange(dataMin, dataMax, axis.min, axis.max, "yAxis.min")
    }
}
