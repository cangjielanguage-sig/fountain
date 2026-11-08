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
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

/** 面积图的一个系列。 */
internal class AreaSeries {
    let name: String
    let points: Array<LinePoint>
    let color: ?String
    let smooth: Bool
    let symbol: String
    let symbolSize: Float64
    let opacity: Float64

    init(
        name: String,
        points: Array<LinePoint>,
        color: ?String,
        smooth: Bool,
        symbol: String,
        symbolSize: Float64,
        opacity: Float64
    ) {
        this.name = name
        this.points = points
        this.color = color
        this.smooth = smooth
        this.symbol = symbol
        this.symbolSize = symbolSize
        this.opacity = opacity
    }
}

/**
 * M14 面积图。
 *
 * 折线下方填充到 0 基线；支持类目数值数组与 `{x,y}` 连续点。
 */
public class AreaChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "area")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }

        var continuousFlag: ?Bool = None
        let series = ArrayList<AreaSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let dataArray = json.requiredArray("data")
            let items = dataArray.getItems()
            let isContinuous = determineContinuous(items, "${path}.data")
            match (continuousFlag) {
                case Some(previous) =>
                    if (previous != isContinuous) {
                        throw chartInvalidValue(
                            "${path}.data",
                            "同一图内不能混用数值数组与 {x,y} 对象数组"
                        )
                    }
                case None => continuousFlag = Some(isContinuous)
            }
            let points = if (isContinuous) {
                parseContinuousPoints(items, "${path}.data", config.xAxis.axisType)
            } else {
                parseCategoryPoints(items, "${path}.data")
            }
            let color = json.string("color")
            let smooth = json.bool("smooth", default: false)
            let symbol = json.string("symbol", default: "none")
            let symbolSize = json.number("symbolSize", default: 6.0)
            let opacity = resolveOpacity(json.value("areaStyle"), "${path}.areaStyle")
            series.add(AreaSeries(name, points, color, smooth, symbol, symbolSize, opacity))
            seriesIndex++
        }

        let continuous = match (continuousFlag) {
            case Some(value) => value
            case None => false
        }
        let labels = if (continuous) {
            Array<String>()
        } else {
            resolveLabels(config.xAxis.labels, series)
        }
        if (!continuous) {
            validateLengths(series, labels)
        }

        let yRange = resolveYRange(config.yAxis, series)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }

        var xMin = 0.0
        var xMax = 1.0
        var xTicks: Array<Float64> = Array<Float64>()
        var xTickLabels: Array<String> = Array<String>()
        if (continuous) {
            let xRange = resolveXRange(config.xAxis, series)
            xMin = xRange[0]
            xMax = xRange[1]
            xTicks = if (!config.xAxis.values.isEmpty()) {
                config.xAxis.values
            } else {
                chartNiceTicks(xMin, xMax, config.xAxis.tickCount)
            }
            xTickLabels = formatXTicks(xTicks, config.xAxis)
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
        let band = BandScale(frame.plot.x, frame.plot.right(), labels.size)
        let numericX = LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())
        let rawBaseline = yScale.scale(0.0)
        let baselineY = if (rawBaseline < frame.plot.y) {
            frame.plot.y
        } else if (rawBaseline > frame.plot.bottom()) {
            frame.plot.bottom()
        } else {
            rawBaseline
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
            drawSeries(kit, item, color, continuous, band, numericX, yScale, baselineY)
        }

        if (continuous) {
            frame.drawXAxisNumeric(kit, xTicks, numericX, xTickLabels)
        } else {
            frame.drawXAxis(kit, labels, band)
        }
        builder.toSvgString()
    }

    private func determineContinuous(items: ArrayList<JsonValue>, path: String): Bool {
        if (items.isEmpty()) {
            return false
        }
        let first = items[0].kind
        if (first.isObject) {
            return true
        }
        if (first.isNull || first.isInt || first.isDecimal) {
            return false
        }
        throw chartInvalidValue("${path}[0]", "期望数字、null 或 {x,y} 对象")
    }

    private func parseCategoryPoints(items: ArrayList<JsonValue>, path: String): Array<LinePoint> {
        let points = ArrayList<LinePoint>()
        var index = 0
        for (item in items) {
            let itemPath = "${path}[${index}]"
            if (item.kind.isNull) {
                points.add(LinePoint(Float64(index), None<Float64>))
            } else if (item.kind.isInt || item.kind.isDecimal) {
                points.add(LinePoint(Float64(index), Some(jsonNumberValue(item, itemPath))))
            } else {
                throw chartInvalidValue(itemPath, "期望数字或 null")
            }
            index++
        }
        points.toArray()
    }

    private func parseContinuousPoints(
        items: ArrayList<JsonValue>,
        path: String,
        axisType: String
    ): Array<LinePoint> {
        let points = ArrayList<LinePoint>()
        var index = 0
        for (item in items) {
            let itemPath = "${path}[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let xValue = json.required("x")
            let x = if (axisType == "time") {
                if (!xValue.kind.isString) {
                    throw chartInvalidValue("${itemPath}.x", "时间轴 x 期望 YYYY-MM-DD 字符串")
                }
                ChartTime.parseDays(xValue.asString().value, "${itemPath}.x")
            } else {
                jsonNumberValue(xValue, "${itemPath}.x")
            }
            let y = match (json.value("y")) {
                case Some(value) =>
                    if (value.kind.isNull) {
                        None<Float64>
                    } else {
                        Some(jsonNumberValue(value, "${itemPath}.y"))
                    }
                case None => None<Float64>
            }
            points.add(LinePoint(x, y))
            index++
        }
        points.toArray()
    }

    private func resolveOpacity(areaStyle: ?JsonValue, path: String): Float64 {
        match (areaStyle) {
            case Some(value) =>
                if (!value.kind.isObject) {
                    throw chartInvalidValue(path, "期望对象")
                }
                let json = ChartJson.of(value.asObject(), path)
                let opacity = json.number("opacity", default: 0.3)
                if (!(0.0 <= opacity && opacity <= 1.0)) {
                    throw chartInvalidValue(
                        "${path}.opacity",
                        "透明度必须在 0 到 1 之间"
                    )
                }
                opacity
            case None => 0.3
        }
    }

    private func resolveLabels(labels: Array<String>, series: ArrayList<AreaSeries>): Array<String> {
        if (!labels.isEmpty()) {
            return labels
        }
        var longest = 0
        for (item in series) {
            if (item.points.size > longest) {
                longest = item.points.size
            }
        }
        let generated = ArrayList<String>()
        for (index in 0..longest) {
            generated.add((index + 1).toString())
        }
        generated.toArray()
    }

    private func validateLengths(series: ArrayList<AreaSeries>, labels: Array<String>): Unit {
        for (index in 0..series.size) {
            if (series[index].points.size != labels.size) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${series[index].points.size} 与 xAxis.labels 长度 ${labels.size} 不一致"
                )
            }
        }
    }

    private func resolveYRange(axis: ChartAxis, series: ArrayList<AreaSeries>): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        for (item in series) {
            for (point in item.points) {
                match (point.y) {
                    case Some(value) =>
                        if (!hasData) {
                            dataMin = minFloat(0.0, value)
                            dataMax = maxFloat(0.0, value)
                            hasData = true
                        } else {
                            dataMin = minFloat(dataMin, value)
                            dataMax = maxFloat(dataMax, value)
                        }
                    case None => ()
                }
            }
        }
        if (!hasData) {
            dataMin = 0.0
            dataMax = 1.0
        }
        if (dataMin > 0.0) {
            dataMin = 0.0
        }
        if (dataMax < 0.0) {
            dataMax = 0.0
        }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin
        }
        var maximum = match (axis.max) {
            case Some(value) => value
            case None =>
                if (dataMax > 0.0) {
                    dataMax * 1.05
                } else {
                    dataMax
                }
        }
        if (maximum <= minimum) {
            if (axis.min.isSome() || axis.max.isSome()) {
                throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
            }
            maximum = minimum + 1.0
        }
        [minimum, maximum]
    }

    private func resolveXRange(axis: ChartAxis, series: ArrayList<AreaSeries>): Array<Float64> {
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

    private func formatXTicks(ticks: Array<Float64>, axis: ChartAxis): Array<String> {
        let labels = ArrayList<String>()
        for (tick in ticks) {
            labels.add(if (axis.axisType == "time") {
                ChartTime.formatDays(tick)
            } else {
                chartFormatTick(tick, axis.labelFormat)
            })
        }
        labels.toArray()
    }

    private func drawSeries(
        kit: ChartSvgKit,
        series: AreaSeries,
        color: String,
        continuous: Bool,
        band: BandScale,
        numericX: LinearScale,
        yScale: LinearScale,
        baselineY: Float64
    ): Unit {
        var segment = ArrayList<LinePixel>()
        for (index in 0..series.points.size) {
            let point = series.points[index]
            match (point.y) {
                case Some(value) =>
                    let x = if (continuous) {
                        numericX.scale(point.x)
                    } else {
                        band.center(index)
                    }
                    segment.add(LinePixel(x, yScale.scale(value)))
                case None =>
                    flushSegment(kit, series, color, segment, baselineY)
            }
        }
        flushSegment(kit, series, color, segment, baselineY)
    }

    private func flushSegment(
        kit: ChartSvgKit,
        series: AreaSeries,
        color: String,
        segment: ArrayList<LinePixel>,
        baselineY: Float64
    ): Unit {
        if (segment.size >= 2) {
            let builder = StringBuilder()
            builder.append("M ${formatSvgNumber(segment[0].x)} ${formatSvgNumber(segment[0].y)}")
            var index = 1
            while (index < segment.size) {
                let current = segment[index]
                if (series.smooth) {
                    let control = segment[index - 1]
                    builder.append(
                        " Q ${formatSvgNumber(control.x)} ${formatSvgNumber(control.y)} " +
                        "${formatSvgNumber(current.x)} ${formatSvgNumber(current.y)}"
                    )
                } else {
                    builder.append(
                        " L ${formatSvgNumber(current.x)} ${formatSvgNumber(current.y)}"
                    )
                }
                index++
            }
            let linePath = builder.toString()
            let areaPath = linePath +
                " L ${formatSvgNumber(segment[segment.size - 1].x)} ${formatSvgNumber(baselineY)}" +
                " L ${formatSvgNumber(segment[0].x)} ${formatSvgNumber(baselineY)} Z"
            kit.path(
                areaPath, fill: color, className: "area", fillOpacity: series.opacity
            )
            kit.path(linePath, fill: "none", stroke: color, strokeWidth: 2.0, className: "line")
        }
        if (series.symbol != "none") {
            for (point in segment) {
                drawSymbol(kit, point.x, point.y, series, color)
            }
        }
        segment.clear()
    }

    private func drawSymbol(
        kit: ChartSvgKit,
        x: Float64,
        y: Float64,
        series: AreaSeries,
        color: String
    ): Unit {
        match (series.symbol) {
            case "square" => kit.square(x, y, series.symbolSize, fill: color, className: "symbol")
            case "diamond" => kit.diamond(x, y, series.symbolSize, fill: color, className: "symbol")
            case _ => kit.circle(x, y, series.symbolSize / 2.0, fill: color, className: "symbol")
        }
    }
}
