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

/** 箱线散点图的一组数据。 */
internal class BoxScatterGroup {
    let name: String
    let values: Array<Float64>

    init(name: String, values: Array<Float64>) {
        this.name = name
        this.values = values
    }
}

/** M45 箱线图 + 散点组合图。 */
public class BoxScatterChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "box-scatter")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "箱线散点图仅支持 1 个系列")
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
        let groups = ArrayList<BoxScatterGroup>()
        if (items[0].kind.isArray) {
            for (groupIndex in 0..items.size) {
                let groupPath = "series[0].data[${groupIndex}]"
                if (!items[groupIndex].kind.isArray) {
                    throw chartInvalidValue(groupPath, "同一图内不能混用嵌套数组与扁平数值")
                }
                let values = parseValues(items[groupIndex].asArray().getItems(), groupPath)
                if (values.isEmpty()) {
                    throw chartInvalidValue(groupPath, "每组数据不能为空")
                }
                let name = if (groupIndex < labels.size) {
                    labels[groupIndex]
                } else {
                    (groupIndex + 1).toString()
                }
                groups.add(BoxScatterGroup(name, values))
            }
            if (!labels.isEmpty() && labels.size != groups.size) {
                throw chartInvalidValue(
                    "xAxis.labels",
                    "标签长度 ${labels.size} 与分组数 ${groups.size} 不一致"
                )
            }
        } else {
            let values = parseValues(items, "series[0].data")
            let name = if (!labels.isEmpty()) {
                labels[0]
            } else if (!seriesName.isEmpty()) {
                seriesName
            } else {
                "1"
            }
            groups.add(BoxScatterGroup(name, values))
        }

        let showBox = seriesJson.bool("showBox", default: true)
        let jitter = seriesJson.number("jitter", default: 0.15)
        if (jitter < 0.0 || jitter > 1.0) {
            throw chartInvalidValue("series[0].jitter", "jitter 必须在 0–1 之间")
        }

        var dataMin = groups[0].values[0]
        var dataMax = groups[0].values[0]
        for (group in groups) {
            for (value in group.values) {
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
        let band = BandScale(frame.plot.x, frame.plot.right(), groups.size)
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

        let halfWidth = band.bandWidth / 2.0
        let boxWidth = band.bandWidth * 0.32
        for (groupIndex in 0..groups.size) {
            let group = groups[groupIndex]
            let center = band.center(groupIndex)
            if (showBox) {
                let sorted = sortValues(group.values)
                let bounds = boxScatterBounds(sorted)
                let lowY = yScale.scale(bounds[0])
                let highY = yScale.scale(bounds[4])
                let q1Y = yScale.scale(bounds[1])
                let medianY = yScale.scale(bounds[2])
                let q3Y = yScale.scale(bounds[3])
                kit.line(
                    center, lowY, center, highY,
                    stroke: color, strokeWidth: 1.0, className: "box-scatter-whisker"
                )
                kit.line(
                    center - boxWidth / 2.0, lowY, center + boxWidth / 2.0, lowY,
                    stroke: color, strokeWidth: 1.0, className: "box-scatter-cap"
                )
                kit.line(
                    center - boxWidth / 2.0, highY, center + boxWidth / 2.0, highY,
                    stroke: color, strokeWidth: 1.0, className: "box-scatter-cap"
                )
                let boxTop = minFloat(q1Y, q3Y)
                let boxHeight = abs(q3Y - q1Y)
                kit.rect(
                    center - boxWidth / 2.0, boxTop, boxWidth, boxHeight,
                    fill: "#ffffff", stroke: color, strokeWidth: 1.0,
                    className: "box-scatter-box", fillOpacity: 0.9
                )
                kit.line(
                    center - boxWidth / 2.0, medianY,
                    center + boxWidth / 2.0, medianY,
                    stroke: color, strokeWidth: 2.0, className: "box-scatter-median"
                )
            }
            let offsets = swarmOffsets(group.values.size, jitter, "both")
            for (pointIndex in 0..group.values.size) {
                kit.circle(
                    center + offsets[pointIndex] * halfWidth,
                    yScale.scale(group.values[pointIndex]),
                    3.0,
                    fill: color,
                    className: "box-scatter-point"
                )
            }
        }
        let groupLabels = ArrayList<String>()
        for (group in groups) {
            groupLabels.add(group.name)
        }
        frame.drawXAxis(kit, groupLabels.toArray(), band)
        builder.toSvgString()
    }

    private func parseValues(items: ArrayList<JsonValue>, path: String): Array<Float64> {
        let values = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "${path}[${index}]"
            if (!(item.kind.isInt || item.kind.isDecimal)) {
                throw chartInvalidValue(itemPath, "期望数字")
            }
            values.add(jsonNumberValue(item, itemPath))
            index++
        }
        values.toArray()
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

    private func sortValues(values: Array<Float64>): Array<Float64> {
        let sorted = ArrayList<Float64>()
        for (value in values) {
            sorted.add(value)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && sorted[j] < sorted[j - 1]) {
                let temporary = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = temporary
                j--
            }
        }
        sorted.toArray()
    }
}

/** 五数概括：`[下须, Q1, 中位数, Q3, 上须]`，须线取 1.5 IQR 栅栏内最值。 */
internal func boxScatterBounds(sorted: Array<Float64>): Array<Float64> {
    if (sorted.isEmpty()) {
        return [0.0, 0.0, 0.0, 0.0, 0.0]
    }
    let q1 = quantileSorted(sorted, 0.25)
    let median = quantileSorted(sorted, 0.5)
    let q3 = quantileSorted(sorted, 0.75)
    let iqr = q3 - q1
    let lowFence = q1 - 1.5 * iqr
    let highFence = q3 + 1.5 * iqr
    var low = sorted[0]
    for (value in sorted) {
        if (value >= lowFence) {
            low = value
            break
        }
    }
    var high = sorted[sorted.size - 1]
    var index = sorted.size - 1
    while (index >= 0) {
        if (sorted[index] <= highFence) {
            high = sorted[index]
            break
        }
        index--
    }
    [low, q1, median, q3, high]
}
