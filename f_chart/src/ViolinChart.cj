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

/** 小提琴图的一组分布。 */
internal class ViolinGroup {
    let name: String
    let values: Array<Float64>

    init(name: String, values: Array<Float64>) {
        this.name = name
        this.values = values
    }
}

/**
 * M20 小提琴图。
 *
 * 每组数据用高斯核密度镜像成轮廓，并可选叠加箱体与中位线。
 */
public class ViolinChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "violin")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "小提琴图仅支持 1 个系列")
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
        let groups = ArrayList<ViolinGroup>()
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
                groups.add(ViolinGroup(name, values))
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
            groups.add(ViolinGroup(name, values))
        }

        let bandwidth = match (seriesJson.number("bandwidth")) {
            case Some(value) =>
                if (value <= 0.0 || value.isNaN() || value.isInf()) {
                    throw chartInvalidValue("series[0].bandwidth", "带宽必须大于 0")
                }
                Some(value)
            case None => None<Float64>
        }
        let showBox = seriesJson.bool("showBox", default: true)

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

        for (groupIndex in 0..groups.size) {
            let group = groups[groupIndex]
            let groupBandwidth = match (bandwidth) {
                case Some(value) => value
                case None => defaultBandwidth(group.values)
            }
            let center = band.center(groupIndex)
            let maxHalf = band.bandWidth * 0.4
            let points = ArrayList<Float64>()
            let widths = ArrayList<Float64>()
            var peak = 0.0
            for (step in 0..=40) {
                let value = yRange[0] + (yRange[1] - yRange[0]) * Float64(step) / 40.0
                let density = gaussianKde(group.values, groupBandwidth, value)
                if (density > peak) {
                    peak = density
                }
                points.add(value)
                widths.add(density)
            }
            if (peak > 0.0) {
                let path = StringBuilder()
                path.append(
                    "M ${formatSvgNumber(center)} ${formatSvgNumber(yScale.scale(points[0]))}"
                )
                for (step in 0..widths.size) {
                    let half = widths[step] / peak * maxHalf
                    path.append(
                        " L ${formatSvgNumber(center + half)} " +
                        "${formatSvgNumber(yScale.scale(points[step]))}"
                    )
                }
                var reverse = widths.size - 1
                while (reverse >= 0) {
                    let half = widths[reverse] / peak * maxHalf
                    path.append(
                        " L ${formatSvgNumber(center - half)} " +
                        "${formatSvgNumber(yScale.scale(points[reverse]))}"
                    )
                    reverse--
                }
                path.append(" Z")
                kit.path(
                    path.toString(), fill: color, stroke: color, strokeWidth: 1.0,
                    className: "violin", fillOpacity: 0.35
                )
            }
            if (showBox) {
                let sorted = sortValues(group.values)
                let q1 = quantileSorted(sorted, 0.25)
                let median = quantileSorted(sorted, 0.5)
                let q3 = quantileSorted(sorted, 0.75)
                let boxWidth = band.bandWidth * 0.1
                let boxTop = minFloat(yScale.scale(q1), yScale.scale(q3))
                let boxHeight = abs(yScale.scale(q3) - yScale.scale(q1))
                kit.rect(
                    center - boxWidth / 2.0, boxTop, boxWidth, boxHeight,
                    fill: "#ffffff", stroke: color, strokeWidth: 1.0,
                    className: "box", fillOpacity: 0.9
                )
                kit.line(
                    center - boxWidth / 2.0, yScale.scale(median),
                    center + boxWidth / 2.0, yScale.scale(median),
                    stroke: color, strokeWidth: 2.0, className: "median"
                )
            }
        }
        let labels2 = ArrayList<String>()
        for (group in groups) {
            labels2.add(group.name)
        }
        frame.drawXAxis(kit, labels2.toArray(), band)
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

/** 已排序数组的分位数（最近秩）。 */
internal func quantileSorted(sorted: Array<Float64>, p: Float64): Float64 {
    if (sorted.isEmpty()) {
        return 0.0
    }
    if (sorted.size == 1) {
        return sorted[0]
    }
    let position = Int64(floor(p * Float64(sorted.size - 1)))
    let index = if (position < 0) {
        0
    } else if (position >= sorted.size) {
        sorted.size - 1
    } else {
        position
    }
    sorted[index]
}
