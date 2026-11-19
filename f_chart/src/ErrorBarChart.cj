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
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 误差线数据点：中心值与上下界。 */
internal class ErrorBarPoint {
    let label: String
    let x: Float64
    let y: Float64
    let low: Float64
    let high: Float64

    init(label: String, x: Float64, y: Float64, low: Float64, high: Float64) {
        this.label = label
        this.x = x
        this.y = y
        this.low = low
        this.high = high
    }
}

/** M39 误差线图：中心值与上下界。 */
public class ErrorBarChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "error-bar")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "误差线图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let color = match (seriesJson.string("color")) {
            case Some(value) => value
            case None => config.theme.colorAt(0)
        }
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }

        let continuous = config.xAxis.axisType != "category"
        let categoryLabels = ArrayList<String>()
        for (label in config.xAxis.labels) {
            categoryLabels.add(label)
        }
        let points = ArrayList<ErrorBarPoint>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x, y, low, high} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            var label = ""
            var x = 0.0
            if (continuous) {
                let xValue = json.required("x")
                x = if (config.xAxis.axisType == "time") {
                    if (!xValue.kind.isString) {
                        throw chartInvalidValue("${itemPath}.x", "时间轴 x 期望 YYYY-MM-DD 字符串")
                    }
                    ChartTime.parseDays(xValue.asString().value, "${itemPath}.x")
                } else {
                    jsonNumberValue(xValue, "${itemPath}.x")
                }
                label = chartFormatTick(x, config.xAxis.labelFormat)
            } else {
                let xValue = json.required("x")
                if (!xValue.kind.isString) {
                    throw chartInvalidValue("${itemPath}.x", "类别 x 期望字符串")
                }
                label = xValue.asString().value
                let position = indexOfLabel(categoryLabels, label)
                if (position >= 0) {
                    x = Float64(position)
                } else if (config.xAxis.labels.isEmpty()) {
                    categoryLabels.add(label)
                    x = Float64(categoryLabels.size - 1)
                } else {
                    throw chartInvalidValue("${itemPath}.x", "类目 ${label} 不在 xAxis.labels 中")
                }
            }
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            let low = jsonNumberValue(json.required("low"), "${itemPath}.low")
            let high = jsonNumberValue(json.required("high"), "${itemPath}.high")
            if (low > high) {
                throw chartInvalidValue("${itemPath}.low", "low 必须不大于 high")
            }
            if (y < low || y > high) {
                throw chartInvalidValue("${itemPath}.y", "y 必须落在 [low, high] 内")
            }
            points.add(ErrorBarPoint(label, x, y, low, high))
            index++
        }

        let yRange = resolveYRange(config.yAxis, points)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
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
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight
        )
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())

        var band: Option<BandScale> = None
        var xScale: Option<LinearScale> = None
        var xTicks = Array<Float64>()
        var xTickLabels = Array<String>()
        if (continuous) {
            let xRange = resolveXRange(config.xAxis, points)
            xTicks = if (!config.xAxis.values.isEmpty()) {
                config.xAxis.values
            } else {
                chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
            }
            let labels = ArrayList<String>()
            for (tick in xTicks) {
                labels.add(if (config.xAxis.axisType == "time") {
                    ChartTime.formatDays(tick)
                } else {
                    chartFormatTick(tick, config.xAxis.labelFormat)
                })
            }
            xTickLabels = labels.toArray()
            xScale = Some(LinearScale(xRange[0], xRange[1], frame.plot.x, frame.plot.right()))
        } else {
            band = Some(BandScale(frame.plot.x, frame.plot.right(), categoryLabels.size))
        }

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) { [color] } else { Array<String>() }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        var capHalf = 5.0
        match (band) {
            case Some(value) => capHalf = minFloat(12.0, value.bandWidth * 0.3) / 2.0
            case None => ()
        }
        for (point in points) {
            let x = match (band) {
                case Some(value) => value.center(Int64(point.x))
                case None => match (xScale) {
                    case Some(scale) => scale.scale(point.x)
                    case None => frame.plot.x
                }
            }
            let highY = yScale.scale(point.high)
            let lowY = yScale.scale(point.low)
            kit.line(
                x, highY, x, lowY,
                stroke: color, strokeWidth: 1.5, className: "error-bar-line"
            )
            kit.line(
                x - capHalf, highY, x + capHalf, highY,
                stroke: color, strokeWidth: 1.5, className: "error-bar-cap"
            )
            kit.line(
                x - capHalf, lowY, x + capHalf, lowY,
                stroke: color, strokeWidth: 1.5, className: "error-bar-cap"
            )
            kit.circle(x, yScale.scale(point.y), 3.0, fill: color, className: "error-bar-point")
        }

        match (band) {
            case Some(value) => frame.drawXAxis(kit, categoryLabels.toArray(), value)
            case None => match (xScale) {
                case Some(scale) => frame.drawXAxisNumeric(kit, xTicks, scale, xTickLabels)
                case None => ()
            }
        }
        builder.toSvgString()
    }

    private func indexOfLabel(labels: ArrayList<String>, label: String): Int64 {
        for (index in 0..labels.size) {
            if (labels[index] == label) {
                return index
            }
        }
        -1
    }

    private func resolveYRange(axis: ChartAxis, points: ArrayList<ErrorBarPoint>): Array<Float64> {
        var dataMin = points[0].low
        var dataMax = points[0].high
        for (point in points) {
            dataMin = minFloat(dataMin, minFloat(point.low, point.y))
            dataMax = maxFloat(dataMax, maxFloat(point.high, point.y))
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.08
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.08
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        [minimum, maximum]
    }

    private func resolveXRange(axis: ChartAxis, points: ArrayList<ErrorBarPoint>): Array<Float64> {
        var dataMin = points[0].x
        var dataMax = points[0].x
        for (point in points) {
            dataMin = minFloat(dataMin, point.x)
            dataMax = maxFloat(dataMax, point.x)
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.05
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.05
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        [minimum, maximum]
    }
}
