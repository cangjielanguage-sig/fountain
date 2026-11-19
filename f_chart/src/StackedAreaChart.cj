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

/** 堆叠面积图的一个系列。 */
internal class StackedAreaSeries {
    let name: String
    let stack: String
    let values: Array<Float64>
    let color: ?String
    let opacity: Float64

    init(name: String, stack: String, values: Array<Float64>, color: ?String, opacity: Float64) {
        this.name = name
        this.stack = stack
        this.values = values
        this.color = color
        this.opacity = opacity
    }
}

/**
 * M15 堆叠面积图。
 *
 * 类目模式下按 `stack` 分组累加，每个系列填充「前序累计 → 本层累计」的区间。
 */
public class StackedAreaChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "stacked-area")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }

        let series = ArrayList<StackedAreaSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let stack = json.string("stack", default: "")
            let dataArray = json.requiredArray("data")
            let values = ArrayList<Float64>()
            var valueIndex = 0
            for (entry in dataArray.getItems()) {
                let itemPath = "${path}.data[${valueIndex}]"
                if (entry.kind.isNull) {
                    values.add(0.0)
                } else if (entry.kind.isInt || entry.kind.isDecimal) {
                    values.add(jsonNumberValue(entry, itemPath))
                } else {
                    throw chartInvalidValue(itemPath, "堆叠面积图仅支持数值数组")
                }
                valueIndex++
            }
            let color = json.string("color")
            let opacity = resolveOpacity(json.value("areaStyle"), "${path}.areaStyle")
            series.add(StackedAreaSeries(name, stack, values.toArray(), color, opacity))
            seriesIndex++
        }

        let labels = resolveLabels(config.xAxis.labels, series)
        for (index in 0..series.size) {
            if (series[index].values.size != labels.size) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${series[index].values.size} 与 xAxis.labels 长度 ${labels.size} 不一致"
                )
            }
        }

        let groups = ArrayList<String>()
        for (item in series) {
            groups.add(item.stack)
        }
        let values = ArrayList<Array<Float64>>()
        for (item in series) {
            values.add(item.values)
        }
        let bounds = stackedAreaBounds(groups.toArray(), values.toArray(), labels.size)
        let yRange = resolveYRange(config.yAxis, bounds)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
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
        if (labels.isEmpty()) {
            frame.drawXAxis(kit, labels, band)
            return builder.toSvgString()
        }
        let groupIndexes = groupIndexesOf(groups.toArray())
        let groupCount = uniqueGroupCount(groupIndexes)
        let lowerLayers = ArrayList<Array<Float64>>()
        let upperLayers = ArrayList<Array<Float64>>()
        for (_ in 0..series.size) {
            let lower = ArrayList<Float64>()
            let upper = ArrayList<Float64>()
            for (_ in 0..labels.size) {
                lower.add(0.0)
                upper.add(0.0)
            }
            lowerLayers.add(lower.toArray())
            upperLayers.add(upper.toArray())
        }
        var cums = ArrayList<Float64>()
        for (_ in 0..groupCount) {
            cums.add(0.0)
        }
        for (category in 0..labels.size) {
            for (index in 0..cums.size) {
                cums[index] = 0.0
            }
            for (seriesIndex in 0..series.size) {
                let groupIndex = groupIndexes[seriesIndex]
                let lower = cums[groupIndex]
                let upper = lower + series[seriesIndex].values[category]
                cums[groupIndex] = upper
                lowerLayers[seriesIndex][category] = lower
                upperLayers[seriesIndex][category] = upper
            }
        }
        for (seriesIndex in 0..series.size) {
            let color = match (series[seriesIndex].color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            let upper = upperLayers[seriesIndex]
            let lower = lowerLayers[seriesIndex]
            let areaBuilder = StringBuilder()
            areaBuilder.append(
                "M ${formatSvgNumber(band.center(0))} ${formatSvgNumber(yScale.scale(upper[0]))}"
            )
            for (category in 1..labels.size) {
                areaBuilder.append(
                    " L ${formatSvgNumber(band.center(category))} " +
                    "${formatSvgNumber(yScale.scale(upper[category]))}"
                )
            }
            var reverse = labels.size - 1
            while (reverse >= 0) {
                areaBuilder.append(
                    " L ${formatSvgNumber(band.center(reverse))} " +
                    "${formatSvgNumber(yScale.scale(lower[reverse]))}"
                )
                reverse--
            }
            areaBuilder.append(" Z")
            kit.path(
                areaBuilder.toString(),
                fill: color,
                className: "stacked-area",
                fillOpacity: series[seriesIndex].opacity
            )

            let edgeBuilder = StringBuilder()
            edgeBuilder.append(
                "M ${formatSvgNumber(band.center(0))} ${formatSvgNumber(yScale.scale(upper[0]))}"
            )
            for (category in 1..labels.size) {
                edgeBuilder.append(
                    " L ${formatSvgNumber(band.center(category))} " +
                    "${formatSvgNumber(yScale.scale(upper[category]))}"
                )
            }
            kit.path(
                edgeBuilder.toString(),
                fill: "none",
                stroke: color,
                strokeWidth: 1.5,
                className: "line"
            )
        }
        frame.drawXAxis(kit, labels, band)
        builder.toSvgString()
    }

    private func resolveOpacity(areaStyle: ?JsonValue, path: String): Float64 {
        match (areaStyle) {
            case Some(value) =>
                if (!value.kind.isObject) {
                    throw chartInvalidValue(path, "期望对象")
                }
                let json = ChartJson.of(value.asObject(), path)
                let opacity = json.number("opacity", default: 0.6)
                if (!(0.0 <= opacity && opacity <= 1.0)) {
                    throw chartInvalidValue(
                        "${path}.opacity",
                        "透明度必须在 0 到 1 之间"
                    )
                }
                opacity
            case None => 0.6
        }
    }

    private func resolveLabels(
        labels: Array<String>,
        series: ArrayList<StackedAreaSeries>
    ): Array<String> {
        if (!labels.isEmpty()) {
            return labels
        }
        var longest = 0
        for (item in series) {
            if (item.values.size > longest) {
                longest = item.values.size
            }
        }
        let generated = ArrayList<String>()
        for (index in 0..longest) {
            generated.add((index + 1).toString())
        }
        generated.toArray()
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

/** 每个系列所属分组的下标（按首次出现顺序去重）。 */
internal func groupIndexesOf(groups: Array<String>): Array<Int64> {
    let unique = ArrayList<String>()
    let indexes = ArrayList<Int64>()
    for (group in groups) {
        var position = -1
        for (index in 0..unique.size) {
            if (unique[index] == group) {
                position = index
                break
            }
        }
        if (position < 0) {
            position = unique.size
            unique.add(group)
        }
        indexes.add(position)
    }
    indexes.toArray()
}

/** 分组去重后的数量。 */
internal func uniqueGroupCount(indexes: Array<Int64>): Int64 {
    var count = 0
    for (index in indexes) {
        if (index + 1 > count) {
            count = index + 1
        }
    }
    count
}

/**
 * 堆叠面积图的累计范围。
 *
 * `values[s][c]` 为系列 s 在类目 c 的值；`groups[s]` 为系列 s 的 stack 键。
 * 返回 `[min, max]`，始终包含 0。
 */
internal func stackedAreaBounds(
    groups: Array<String>,
    values: Array<Array<Float64>>,
    count: Int64
): Array<Float64> {
    var minimum = 0.0
    var maximum = 0.0
    let indexes = groupIndexesOf(groups)
    let groupCount = uniqueGroupCount(indexes)
    let cums = ArrayList<Float64>()
    for (_ in 0..groupCount) {
        cums.add(0.0)
    }
    for (category in 0..count) {
        for (index in 0..cums.size) {
            cums[index] = 0.0
        }
        for (seriesIndex in 0..values.size) {
            let groupIndex = indexes[seriesIndex]
            let next = cums[groupIndex] + values[seriesIndex][category]
            cums[groupIndex] = next
            if (next < minimum) {
                minimum = next
            }
            if (next > maximum) {
                maximum = next
            }
        }
    }
    [minimum, maximum]
}
