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

/** 箱线图的五数概括与异常值。 */
internal class BoxStats {
    let name: String
    let minimum: Float64
    let q1: Float64
    let median: Float64
    let q3: Float64
    let maximum: Float64
    let outliers: Array<Float64>

    init(
        name: String,
        minimum: Float64,
        q1: Float64,
        median: Float64,
        q3: Float64,
        maximum: Float64,
        outliers: Array<Float64>
    ) {
        this.name = name
        this.minimum = minimum
        this.q1 = q1
        this.median = median
        this.q3 = q3
        this.maximum = maximum
        this.outliers = outliers
    }
}

/**
 * M19 箱线图。
 *
 * 每个类别按五数概括绘制箱体、须、端帽与异常值。
 */
public class BoxPlotChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "boxplot")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "箱线图仅支持 1 个系列")
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

        let stats = ArrayList<BoxStats>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {min,q1,median,q3,max} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let minimum = requiredNumber(json, "min", itemPath)
            let q1 = requiredNumber(json, "q1", itemPath)
            let median = requiredNumber(json, "median", itemPath)
            let q3 = requiredNumber(json, "q3", itemPath)
            let maximum = requiredNumber(json, "max", itemPath)
            if (!(minimum <= q1 && q1 <= median && median <= q3 && q3 <= maximum)) {
                throw chartInvalidValue(
                    itemPath,
                    "五数必须满足 min <= q1 <= median <= q3 <= max"
                )
            }
            let outliers = ArrayList<Float64>()
            match (json.value("outliers")) {
                case Some(value) =>
                    if (!value.kind.isArray) {
                        throw chartInvalidValue("${itemPath}.outliers", "期望数组")
                    }
                    var outlierIndex = 0
                    for (entry in value.asArray().getItems()) {
                        let outlierPath = "${itemPath}.outliers[${outlierIndex}]"
                        if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                            throw chartInvalidValue(outlierPath, "期望数字")
                        }
                        outliers.add(jsonNumberValue(entry, outlierPath))
                        outlierIndex++
                    }
                case None => ()
            }
            let defaultName = if (index < labels.size) {
                labels[index]
            } else {
                (index + 1).toString()
            }
            let name = json.string("name", default: defaultName)
            stats.add(BoxStats(name, minimum, q1, median, q3, maximum, outliers.toArray()))
            index++
        }

        var dataMin = stats[0].minimum
        var dataMax = stats[0].maximum
        for (item in stats) {
            dataMin = minFloat(dataMin, item.minimum)
            dataMax = maxFloat(dataMax, item.maximum)
            for (value in item.outliers) {
                dataMin = minFloat(dataMin, value)
                dataMax = maxFloat(dataMax, value)
            }
        }
        let yRange = resolveYRange(config.yAxis, dataMin, dataMax)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }

        let axisLabels = ArrayList<String>()
        for (position in 0..stats.size) {
            axisLabels.add(if (position < labels.size) { labels[position] } else { stats[position].name })
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
        let band = BandScale(frame.plot.x, frame.plot.right(), stats.size)
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())
        let color = match (seriesColor) {
            case Some(value) => value
            case None => config.theme.colorAt(0)
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

        let boxWidth = minFloat(maxFloat(band.bandWidth * 0.5, 12.0), band.bandWidth * 0.9)
        for (position in 0..stats.size) {
            let item = stats[position]
            let center = band.center(position)
            let axisColor = config.theme.axisColor
            kit.line(
                center, yScale.scale(item.minimum), center, yScale.scale(item.q1),
                stroke: axisColor, strokeWidth: 1.0, className: "whisker"
            )
            kit.line(
                center, yScale.scale(item.q3), center, yScale.scale(item.maximum),
                stroke: axisColor, strokeWidth: 1.0, className: "whisker"
            )
            let capWidth = boxWidth * 0.6
            kit.line(
                center - capWidth / 2.0, yScale.scale(item.minimum),
                center + capWidth / 2.0, yScale.scale(item.minimum),
                stroke: axisColor, strokeWidth: 1.0, className: "whisker-cap"
            )
            kit.line(
                center - capWidth / 2.0, yScale.scale(item.maximum),
                center + capWidth / 2.0, yScale.scale(item.maximum),
                stroke: axisColor, strokeWidth: 1.0, className: "whisker-cap"
            )
            let boxTop = minFloat(yScale.scale(item.q1), yScale.scale(item.q3))
            let boxHeight = abs(yScale.scale(item.q3) - yScale.scale(item.q1))
            kit.rect(
                center - boxWidth / 2.0, boxTop, boxWidth, boxHeight,
                fill: color, stroke: color, strokeWidth: 1.5,
                className: "box", fillOpacity: 0.25
            )
            kit.line(
                center - boxWidth / 2.0, yScale.scale(item.median),
                center + boxWidth / 2.0, yScale.scale(item.median),
                stroke: color, strokeWidth: 2.0, className: "median"
            )
            for (outlier in item.outliers) {
                kit.circle(center, yScale.scale(outlier), 3.0, fill: color, className: "outlier")
            }
        }
        frame.drawXAxis(kit, axisLabels.toArray(), band)
        builder.toSvgString()
    }

    private func requiredNumber(json: ChartJson, name: String, path: String): Float64 {
        let value = json.required(name)
        if (!(value.kind.isInt || value.kind.isDecimal)) {
            throw chartInvalidValue("${path}.${name}", "期望数字")
        }
        jsonNumberValue(value, "${path}.${name}")
    }

    private func resolveYRange(axis: ChartAxis, dataMin: Float64, dataMax: Float64): Array<Float64> {
        let span = dataMax - dataMin
        let padding = if (abs(span) < 1e-12) { 1.0 } else { abs(span) * 0.05 }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin - padding
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => dataMax + padding
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        [minimum, maximum]
    }
}
