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

/** 雨云图的一个分组。 */
internal class RaincloudGroup {
    let name: String
    let values: Array<Float64>
    let bandwidth: Option<Float64>
    let showCloud: Bool
    let showRain: Bool
    let showBox: Bool

    init(
        name: String,
        values: Array<Float64>,
        bandwidth: Option<Float64>,
        showCloud: Bool,
        showRain: Bool,
        showBox: Bool
    ) {
        this.name = name
        this.values = values
        this.bandwidth = bandwidth
        this.showCloud = showCloud
        this.showRain = showRain
        this.showBox = showBox
    }
}

/** M88 雨云图。 */
public class RaincloudChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "raincloud")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let groups = ArrayList<RaincloudGroup>()
        var seriesIndex = 0
        for (item in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let dataArray = json.requiredArray("data")
            let dataItems = dataArray.getItems()
            if (dataItems.isEmpty()) {
                throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
            }
            let values = ArrayList<Float64>()
            var dataIndex = 0
            for (value in dataItems) {
                if (!(value.kind.isInt || value.kind.isDecimal)) {
                    throw chartInvalidValue(
                        "${seriesPath}.data[${dataIndex}]", "期望数字"
                    )
                }
                values.add(jsonNumberValue(value, "${seriesPath}.data[${dataIndex}]"))
                dataIndex++
            }
            let bandwidth = json.number("bandwidth")
            match (bandwidth) {
                case Some(value) =>
                    if (value <= 0.0) {
                        throw chartInvalidValue("${seriesPath}.bandwidth", "带宽必须大于 0")
                    }
                case None => ()
            }
            groups.add(RaincloudGroup(
                json.string("name", default: (seriesIndex + 1).toString()),
                values.toArray(),
                bandwidth,
                json.bool("showCloud", default: true),
                json.bool("showRain", default: true),
                json.bool("showBox", default: true)
            ))
            seriesIndex++
        }
        let groupArray = groups.toArray()

        let labels = ArrayList<String>()
        for (index in 0..groupArray.size) {
            let name = if (index < config.xAxis.labels.size) {
                config.xAxis.labels[index]
            } else {
                groupArray[index].name
            }
            labels.add(name)
        }

        var dataMin = groupArray[0].values[0]
        var dataMax = dataMin
        for (group in groupArray) {
            for (value in group.values) {
                dataMin = minFloat(dataMin, value)
                dataMax = maxFloat(dataMax, value)
            }
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.08
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.08
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in yTicks) {
            tickLabels.add(chartFormatTick(tick, config.yAxis.labelFormat))
        }

        let legendVisible = config.legend.show && groupArray.size > 1
        var maxYLabelWidth = 0.0
        for (label in tickLabels) {
            maxYLabelWidth = maxFloat(maxYLabelWidth, chartTextWidth(label, config.theme.fontSize))
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), groupArray.size)
        let yScale = LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())

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
        for (index in 0..groupArray.size) {
            names.add(groupArray[index].name)
            colors.add(config.theme.colorAt(index))
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        for (index in 0..groupArray.size) {
            let group = groupArray[index]
            let color = colors[index]
            let center = band.center(index)
            let halfWidth = band.bandWidth * 0.35

            if (group.showCloud) {
                drawCloud(kit, group, color, center, halfWidth, yScale)
            }
            if (group.showRain) {
                let jitter = band.bandWidth * 0.15
                let offsets = swarmOffsets(group.values.size, jitter, "left")
                let baseX = center - band.bandWidth * 0.18
                for (position in 0..group.values.size) {
                    kit.circle(
                        baseX + offsets[position],
                        yScale.scale(group.values[position]),
                        2.5,
                        fill: color,
                        className: "raincloud-rain"
                    )
                }
            }
            if (group.showBox) {
                drawBox(kit, group, color, center, band.bandWidth * 0.1, yScale)
            }
        }
        frame.drawXAxis(kit, labels.toArray(), band)
        builder.toSvgString()
    }

    private func drawCloud(
        kit: ChartSvgKit,
        group: RaincloudGroup,
        color: String,
        center: Float64,
        halfWidth: Float64,
        yScale: LinearScale
    ): Unit {
        let bandwidth = match (group.bandwidth) {
            case Some(value) => value
            case None => defaultBandwidth(group.values)
        }
        var low = group.values[0]
        var high = group.values[0]
        for (value in group.values) {
            low = minFloat(low, value)
            high = maxFloat(high, value)
        }
        let samples: Int64 = 48
        let step = if (samples <= 1) { 0.0 } else { (high - low) / Float64(samples - 1) }
        let densities = ArrayList<Float64>()
        var peak = 0.0
        for (index in 0..samples) {
            let value = low + step * Float64(index)
            let density = gaussianKde(group.values, bandwidth, value)
            peak = maxFloat(peak, density)
            densities.add(density)
        }
        if (peak <= 0.0) {
            return
        }
        let path = StringBuilder()
        for (index in 0..samples) {
            let value = low + step * Float64(index)
            let x = center + halfWidth * densities[index] / peak
            let y = yScale.scale(value)
            if (index == 0) {
                path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            } else {
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            }
        }
        path.append(" L ${formatSvgNumber(center)} ${formatSvgNumber(yScale.scale(high))}")
        path.append(" L ${formatSvgNumber(center)} ${formatSvgNumber(yScale.scale(low))} Z")
        kit.path(
            path.toString(),
            fill: color,
            stroke: color,
            strokeWidth: 1.0,
            className: "raincloud-cloud",
            fillOpacity: 0.35
        )
    }

    private func drawBox(
        kit: ChartSvgKit,
        group: RaincloudGroup,
        color: String,
        center: Float64,
        width: Float64,
        yScale: LinearScale
    ): Unit {
        let sorted = sortRaincloud(group.values)
        let bounds = boxScatterBounds(sorted)
        let low = bounds[0]
        let q1 = bounds[1]
        let median = bounds[2]
        let q3 = bounds[3]
        let high = bounds[4]
        let top = minFloat(yScale.scale(q1), yScale.scale(q3))
        let height = maxFloat(abs(yScale.scale(q3) - yScale.scale(q1)), 1.0)
        kit.rect(
            center - width / 2.0, top, width, height,
            fill: "#ffffff", stroke: color, strokeWidth: 1.0,
            className: "raincloud-box"
        )
        kit.line(
            center - width / 2.0, yScale.scale(median),
            center + width / 2.0, yScale.scale(median),
            stroke: color, strokeWidth: 1.5, className: "raincloud-median"
        )
        kit.line(
            center, yScale.scale(q1), center, yScale.scale(low),
            stroke: color, strokeWidth: 1.0, className: "raincloud-whisker"
        )
        kit.line(
            center, yScale.scale(q3), center, yScale.scale(high),
            stroke: color, strokeWidth: 1.0, className: "raincloud-whisker"
        )
        kit.line(
            center - width * 0.4, yScale.scale(low),
            center + width * 0.4, yScale.scale(low),
            stroke: color, strokeWidth: 1.0, className: "raincloud-cap"
        )
        kit.line(
            center - width * 0.4, yScale.scale(high),
            center + width * 0.4, yScale.scale(high),
            stroke: color, strokeWidth: 1.0, className: "raincloud-cap"
        )
        for (value in sorted) {
            if (value < low || value > high) {
                kit.circle(center, yScale.scale(value), 2.5, fill: color, className: "raincloud-outlier")
            }
        }
    }
}

/** 插入排序，保证确定性。 */
internal func sortRaincloud(values: Array<Float64>): Array<Float64> {
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
