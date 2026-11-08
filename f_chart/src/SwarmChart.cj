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

/** 蜂群图的一组原始点。 */
internal class SwarmGroup {
    let name: String
    let values: Array<Float64>

    init(name: String, values: Array<Float64>) {
        this.name = name
        this.values = values
    }
}

/**
 * M21 蜂群图 / 抖动图。
 *
 * 原始点按数值排序后分配确定性抖动偏移，避免重叠。
 */
public class SwarmChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "swarm")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "蜂群图仅支持 1 个系列")
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
        let groups = ArrayList<SwarmGroup>()
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
                groups.add(SwarmGroup(name, values))
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
            groups.add(SwarmGroup(name, values))
        }

        let jitter = seriesJson.number("jitter", default: 0.3)
        if (jitter < 0.0 || jitter > 1.0 || jitter.isNaN() || jitter.isInf()) {
            throw chartInvalidValue("series[0].jitter", "抖动宽度必须在 0 到 1 之间")
        }
        let side = seriesJson.string("side", default: "both")
        if (side != "both" && side != "left" && side != "right") {
            throw chartInvalidValue("series[0].side", "期望 both / left / right")
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
        for (groupIndex in 0..groups.size) {
            let sorted = sortValues(groups[groupIndex].values)
            let offsets = swarmOffsets(sorted.size, jitter, side)
            let center = band.center(groupIndex)
            for (pointIndex in 0..sorted.size) {
                kit.circle(
                    center + offsets[pointIndex] * halfWidth,
                    yScale.scale(sorted[pointIndex]),
                    3.0,
                    fill: color,
                    className: "swarm-point"
                )
            }
        }
        let axisLabels = ArrayList<String>()
        for (group in groups) {
            axisLabels.add(group.name)
        }
        frame.drawXAxis(kit, axisLabels.toArray(), band)
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

/**
 * 蜂群抖动偏移：0、+1、-1、+2、-2…，按 side 取单侧或双侧，
 * 再归一化到最大绝对值 `jitter`。
 */
internal func swarmOffsets(count: Int64, jitter: Float64, side: String): Array<Float64> {
    let raw = ArrayList<Float64>()
    for (index in 0..count) {
        var offset = 0.0
        if (index > 0) {
            let magnitude = Float64((index + 1) / 2)
            if (side == "left") {
                offset = -magnitude
            } else if (side == "right") {
                offset = magnitude
            } else {
                offset = if (index % 2 == 1) { magnitude } else { -magnitude }
            }
        }
        raw.add(offset)
    }
    var maxAbs = 0.0
    for (offset in raw) {
        maxAbs = maxFloat(maxAbs, abs(offset))
    }
    let result = ArrayList<Float64>()
    for (offset in raw) {
        result.add(if (maxAbs > 0.0) { offset / maxAbs * jitter } else { 0.0 })
    }
    result.toArray()
}
