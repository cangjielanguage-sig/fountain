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

/** 瀑布图的一个台阶。 */
internal class WaterfallPoint {
    let name: String
    let value: Float64
    let kind: String
    let start: Float64
    let end: Float64

    init(name: String, value: Float64, kind: String, start: Float64, end: Float64) {
        this.name = name
        this.value = value
        this.kind = kind
        this.start = start
        this.end = end
    }
}

/**
 * M16 瀑布图。
 *
 * 数据项 `{name?, value, type?}`：`total` 从 0 起算并重置累计，其余项从当前累计增减。
 */
public class WaterfallChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "waterfall")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "瀑布图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let seriesColor = seriesJson.string("color")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }

        let labels = config.xAxis.labels
        if (!labels.isEmpty() && labels.size != items.size) {
            throw chartInvalidValue(
                "xAxis.labels",
                "标签长度 ${labels.size} 与数据长度 ${items.size} 不一致"
            )
        }

        let points = ArrayList<WaterfallPoint>()
        var running = 0.0
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {name,value,type} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let valueJson = json.required("value")
            if (!(valueJson.kind.isInt || valueJson.kind.isDecimal)) {
                throw chartInvalidValue("${itemPath}.value", "期望数字")
            }
            let value = jsonNumberValue(valueJson, "${itemPath}.value")
            let kindValue = json.string("type")
            let kind = match (kindValue) {
                case Some(value) =>
                    if (value == "total" || value == "increase" || value == "decrease") {
                        value
                    } else {
                        throw chartInvalidValue(
                            "${itemPath}.type",
                            "期望 total / increase / decrease"
                        )
                    }
                case None => if (value >= 0.0) { "increase" } else { "decrease" }
            }
            let defaultName = if (index < labels.size) {
                labels[index]
            } else {
                (index + 1).toString()
            }
            let name = json.string("name", default: defaultName)
            let span = waterfallSpan(kind, value, running)
            points.add(WaterfallPoint(name, value, kind, span[0], span[1]))
            running = span[1]
            index++
        }

        var starts = ArrayList<Float64>()
        var ends = ArrayList<Float64>()
        for (point in points) {
            starts.add(point.start)
            ends.add(point.end)
        }
        let bounds = waterfallBounds(starts.toArray(), ends.toArray())
        let yRange = resolveYRange(config.yAxis, bounds)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }

        let axisLabels = ArrayList<String>()
        for (position in 0..points.size) {
            axisLabels.add(if (position < labels.size) { labels[position] } else { points[position].name })
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
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), points.size)
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

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [match (seriesColor) {
                case Some(value) => value
                case None => config.theme.colorAt(0)
            }]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let barWidth = maxFloat(band.bandWidth * 0.55, 8.0)
        for (position in 0..points.size) {
            let point = points[position]
            let top = minFloat(yScale.scale(point.start), yScale.scale(point.end))
            let height = abs(yScale.scale(point.end) - yScale.scale(point.start))
            let x = band.center(position) - barWidth / 2.0
            let color = match (seriesColor) {
                case Some(value) => value
                case None => waterfallColor(point.kind)
            }
            kit.rect(
                x, top, barWidth, height,
                fill: color, className: "waterfall-bar waterfall-${point.kind}"
            )
            kit.text(
                band.center(position), top - 6.0,
                chartFormatTick(point.value, config.yAxis.labelFormat),
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "bar-label"
            )
            if (position + 1 < points.size) {
                let next = points[position + 1]
                let connectorY = yScale.scale(point.end)
                kit.line(
                    x + barWidth, connectorY,
                    band.center(position + 1) - barWidth / 2.0, yScale.scale(next.start),
                    stroke: config.theme.axisColor,
                    strokeWidth: 1.0,
                    className: "connector",
                    dash: "4 4"
                )
            }
        }
        frame.drawXAxis(kit, axisLabels.toArray(), band)
        builder.toSvgString()
    }

    private func resolveYRange(axis: ChartAxis, bounds: Array<Float64>): Array<Float64> {
        var dataMin = bounds[0]
        var dataMax = bounds[1]
        if (dataMin > 0.0) {
            dataMin = 0.0
        }
        if (dataMax < 0.0) {
            dataMax = 0.0
        }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => if (dataMin < 0.0) { dataMin * 1.05 } else { dataMin }
        }
        var maximum = match (axis.max) {
            case Some(value) => value
            case None => if (dataMax > 0.0) { dataMax * 1.05 } else { dataMax }
        }
        if (maximum <= minimum) {
            if (axis.min.isSome() || axis.max.isSome()) {
                throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
            }
            maximum = minimum + 1.0
        }
        [minimum, maximum]
    }
}

/** 瀑布图台阶的起止值：`total` 从 0 起算，其余从当前累计起算。 */
internal func waterfallSpan(kind: String, value: Float64, running: Float64): Array<Float64> {
    if (kind == "total") {
        [0.0, value]
    } else {
        [running, running + value]
    }
}

/** 瀑布图 y 轴范围：覆盖 0 与所有台阶端点。 */
internal func waterfallBounds(starts: Array<Float64>, ends: Array<Float64>): Array<Float64> {
    var minimum = 0.0
    var maximum = 0.0
    for (value in starts) {
        minimum = minFloat(minimum, value)
        maximum = maxFloat(maximum, value)
    }
    for (value in ends) {
        minimum = minFloat(minimum, value)
        maximum = maxFloat(maximum, value)
    }
    [minimum, maximum]
}

/** 瀑布图语义色。 */
internal func waterfallColor(kind: String): String {
    match (kind) {
        case "increase" => "#4caf50"
        case "decrease" => "#e53935"
        case _ => "#607d8b"
    }
}
