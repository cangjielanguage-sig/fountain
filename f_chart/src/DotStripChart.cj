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

/** 豆图的一个分组。 */
internal class DotStripGroup {
    let name: String
    let values: Array<Float64>
    let jitter: Float64
    let dotSize: Float64

    init(name: String, values: Array<Float64>, jitter: Float64, dotSize: Float64) {
        this.name = name
        this.values = values
        this.jitter = jitter
        this.dotSize = dotSize
    }
}

/** M89 豆图。 */
public class DotStripChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "dot-strip")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let groups = ArrayList<DotStripGroup>()
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
            let jitter = json.number("jitter", default: 0.15)
            if (jitter < 0.0) {
                throw chartInvalidValue("${seriesPath}.jitter", "抖动比例不能为负")
            }
            let dotSize = json.number("dotSize", default: 7.0)
            if (dotSize <= 0.0) {
                throw chartInvalidValue("${seriesPath}.dotSize", "点大小必须大于 0")
            }
            groups.add(DotStripGroup(
                json.string("name", default: (seriesIndex + 1).toString()),
                values.toArray(),
                jitter,
                dotSize
            ))
            seriesIndex++
        }
        let groupArray = groups.toArray()

        let labels = ArrayList<String>()
        for (index in 0..groupArray.size) {
            labels.add(if (index < config.xAxis.labels.size) {
                config.xAxis.labels[index]
            } else {
                groupArray[index].name
            })
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
            for (position in 0..group.values.size) {
                let offset = dotStripOffset(position, group.jitter, band.bandWidth)
                kit.circle(
                    center + offset,
                    yScale.scale(group.values[position]),
                    group.dotSize / 2.0,
                    fill: color,
                    className: "dot-strip-dot"
                )
            }
        }
        frame.drawXAxis(kit, labels.toArray(), band)
        builder.toSvgString()
    }
}

/** 按索引生成确定性抖动偏移，范围 `[-jitter * bandwidth, jitter * bandwidth]`。 */
internal func dotStripOffset(index: Int64, jitter: Float64, bandwidth: Float64): Float64 {
    let raw = sin(Float64(index) * 12.9898 + 4.1414) * 43758.5453
    let fraction = raw - floor(raw)
    (fraction * 2.0 - 1.0) * jitter * bandwidth
}
