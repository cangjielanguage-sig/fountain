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

/**
 * M37 帕累托图。
 *
 * 降序柱表示计数，累计折线表示占比。
 */
public class ParetoChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "pareto")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "帕累托图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let values = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!(item.kind.isInt || item.kind.isDecimal)) {
                throw chartInvalidValue(itemPath, "期望数字")
            }
            let value = jsonNumberValue(item, itemPath)
            if (value < 0.0) {
                throw chartInvalidValue(itemPath, "计数不能为负")
            }
            values.add(value)
            index++
        }
        let labels = config.xAxis.labels
        if (!labels.isEmpty() && labels.size != values.size) {
            throw chartInvalidValue(
                "xAxis.labels",
                "标签长度 ${labels.size} 与数据长度 ${values.size} 不一致"
            )
        }
        let order = paretoOrder(values.toArray())
        let sortedValues = ArrayList<Float64>()
        let sortedLabels = ArrayList<String>()
        for (position in order) {
            sortedValues.add(values[position])
            sortedLabels.add(if (position < labels.size) {
                labels[position]
            } else {
                (position + 1).toString()
            })
        }
        let cumulative = paretoCumulative(sortedValues.toArray())
        let showCumulative = root.bool("showCumulative", default: true)

        var maxValue = 0.0
        for (value in sortedValues) {
            maxValue = maxFloat(maxValue, value)
        }
        if (maxValue <= 0.0) {
            throw chartInvalidValue("series[0].data", "总和必须大于 0")
        }
        let yRange = resolveYRange(config.yAxis, maxValue)
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
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight,
            rightLabelWidth: if (showCumulative) { 42.0 } else { 0.0 }
        )
        let band = BandScale(frame.plot.x, frame.plot.right(), sortedValues.size)
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())
        let percentScale = LinearScale(0.0, 100.0, frame.plot.y, frame.plot.bottom())

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
            [config.theme.colorAt(0)]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let barColor = config.theme.colorAt(0)
        let barWidth = band.bandWidth * 0.6
        for (position in 0..sortedValues.size) {
            let top = yScale.scale(sortedValues[position])
            kit.rect(
                band.center(position) - barWidth / 2.0, top,
                barWidth, frame.plot.bottom() - top,
                fill: barColor, className: "pareto-bar"
            )
        }
        if (showCumulative) {
            let lineColor = config.theme.colorAt(1)
            let path = StringBuilder()
            for (position in 0..sortedValues.size) {
                let x = band.center(position)
                let y = percentScale.scale(cumulative[position])
                if (position == 0) {
                    path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                } else {
                    path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                }
                kit.circle(x, y, 3.0, fill: lineColor, className: "pareto-point")
            }
            kit.path(
                path.toString(), fill: "none", stroke: lineColor, strokeWidth: 2.0,
                className: "pareto-line"
            )
            for (tick in [0.0, 20.0, 40.0, 60.0, 80.0, 100.0]) {
                kit.text(
                    frame.plot.right() + 6.0, percentScale.scale(tick) + config.theme.fontSize / 3.0,
                    "${Int64(tick)}%",
                    size: config.theme.fontSize,
                    color: config.theme.axisColor,
                    className: "percent-label"
                )
            }
        }
        frame.drawXAxis(kit, sortedLabels.toArray(), band)
        builder.toSvgString()
    }

    private func resolveYRange(axis: ChartAxis, maxValue: Float64): Array<Float64> {
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => maxValue * 1.05
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        [minimum, maximum]
    }
}

/** 降序下标（稳定排序）。 */
internal func paretoOrder(values: Array<Float64>): Array<Int64> {
    let order = ArrayList<Int64>()
    for (index in 0..values.size) {
        order.add(index)
    }
    for (i in 1..order.size) {
        var j = i
        while (j > 0 && values[order[j]] > values[order[j - 1]]) {
            let temporary = order[j]
            order[j] = order[j - 1]
            order[j - 1] = temporary
            j--
        }
    }
    order.toArray()
}

/** 累计百分比，最后一项固定为 100。 */
internal func paretoCumulative(values: Array<Float64>): Array<Float64> {
    var total = 0.0
    for (value in values) {
        total += value
    }
    if (total <= 0.0) {
        throw chartInvalidValue("series[0].data", "总和必须大于 0")
    }
    let cumulative = ArrayList<Float64>()
    var running = 0.0
    for (index in 0..values.size) {
        running += values[index]
        if (index == values.size - 1) {
            cumulative.add(100.0)
        } else {
            cumulative.add(running / total * 100.0)
        }
    }
    cumulative.toArray()
}
