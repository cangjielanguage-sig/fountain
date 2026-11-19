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

/** 子弹图的一个数据项。 */
internal class BulletItem {
    let name: String
    let value: Float64
    let target: Float64
    let ranges: Array<Float64>

    init(name: String, value: Float64, target: Float64, ranges: Array<Float64>) {
        this.name = name
        this.value = value
        this.target = target
        this.ranges = ranges
    }
}

/** M76 子弹图。 */
public class BulletChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "bullet")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "子弹图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let items = ArrayList<BulletItem>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let name = json.string("name", default: (itemIndex + 1).toString())
            let value = bulletNumber(json, "value", itemPath)
            let target = bulletNumber(json, "target", itemPath)
            let rangeArray = json.requiredArray("ranges")
            let rangeItems = rangeArray.getItems()
            if (rangeItems.isEmpty()) {
                throw chartInvalidValue("${itemPath}.ranges", "区间不能为空")
            }
            let ranges = ArrayList<Float64>()
            var previous = -1.0
            var rangeIndex = 0
            for (rangeItem in rangeItems) {
                if (!(rangeItem.kind.isInt || rangeItem.kind.isDecimal)) {
                    throw chartInvalidValue("${itemPath}.ranges[${rangeIndex}]", "期望数字")
                }
                let range = jsonNumberValue(rangeItem, "${itemPath}.ranges[${rangeIndex}]")
                if (range <= 0.0) {
                    throw chartInvalidValue("${itemPath}.ranges[${rangeIndex}]", "区间上界必须大于 0")
                }
                if (range <= previous) {
                    throw chartInvalidValue("${itemPath}.ranges", "区间上界必须严格递增")
                }
                ranges.add(range)
                previous = range
                rangeIndex++
            }
            items.add(BulletItem(name, value, target, ranges.toArray()))
            itemIndex++
        }

        let labels = ArrayList<String>()
        if (!config.yAxis.labels.isEmpty()) {
            if (config.yAxis.labels.size != items.size) {
                throw chartInvalidValue("yAxis.labels", "类目数量与数据不一致")
            }
            for (label in config.yAxis.labels) {
                labels.add(label)
            }
        } else {
            for (item in items) {
                labels.add(item.name)
            }
        }

        var dataMax = 0.0
        for (item in items) {
            for (range in item.ranges) {
                dataMax = maxFloat(dataMax, range)
            }
            dataMax = maxFloat(dataMax, item.value)
            dataMax = maxFloat(dataMax, item.target)
        }
        let min = match (config.xAxis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let max = match (config.xAxis.max) {
            case Some(value) => value
            case None => dataMax
        }
        if (max <= min) {
            throw chartInvalidValue("xAxis.max", "最大值必须大于最小值")
        }
        let ticks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(min, max, config.xAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in ticks) {
            tickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        var maxLabelWidth = 0.0
        for (label in labels) {
            maxLabelWidth = maxFloat(maxLabelWidth, chartTextWidth(label, config.theme.fontSize))
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, false, maxLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.y, frame.plot.bottom(), items.size)
        let xScale = LinearScale(min, max, frame.plot.right(), frame.plot.x)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        for (tick in ticks) {
            let x = xScale.scale(tick)
            kit.line(
                x, frame.plot.y, x, frame.plot.bottom(),
                stroke: config.theme.gridColor, strokeWidth: 1.0, className: "grid"
            )
        }

        let baseline = xScale.scale(min)
        for (index in 0..items.size) {
            let item = items[index]
            let centerY = band.center(index)
            let rangeHeight = band.bandWidth * 0.7
            var previous = min
            for (rangeIndex in 0..item.ranges.size) {
                let upper = item.ranges[rangeIndex]
                let left = xScale.scale(previous)
                let right = xScale.scale(upper)
                kit.rect(
                    minFloat(left, right),
                    centerY - rangeHeight / 2.0,
                    abs(right - left),
                    rangeHeight,
                    fill: bulletRangeColor(rangeIndex),
                    className: "bullet-range"
                )
                previous = upper
            }
            let valueX = xScale.scale(item.value)
            let valueHeight = band.bandWidth * 0.28
            kit.rect(
                minFloat(baseline, valueX),
                centerY - valueHeight / 2.0,
                abs(valueX - baseline),
                valueHeight,
                fill: config.theme.colorAt(0),
                className: "bullet-value"
            )
            let targetX = xScale.scale(item.target)
            kit.line(
                targetX,
                centerY - rangeHeight / 2.0,
                targetX,
                centerY + rangeHeight / 2.0,
                stroke: "#444444",
                strokeWidth: 3.0,
                className: "bullet-target"
            )
        }

        for (index in 0..labels.size) {
            kit.text(
                frame.plot.x - 8.0,
                band.center(index),
                labels[index],
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "axis-label"
            )
        }
        frame.drawXAxisNumeric(kit, ticks, xScale, tickLabels.toArray())
        builder.toSvgString()
    }
}

/** 读取必填数字字段，缺失抛 `MissingField`，类型不符抛 `InvalidValue`。 */
internal func bulletNumber(json: ChartJson, field: String, itemPath: String): Float64 {
    let value = json.required(field)
    if (!(value.kind.isInt || value.kind.isDecimal)) {
        throw chartInvalidValue("${itemPath}.${field}", "期望数字")
    }
    let number = jsonNumberValue(value, "${itemPath}.${field}")
    if (number < 0.0) {
        throw chartInvalidValue("${itemPath}.${field}", "数值不能为负")
    }
    number
}

/** 区间色带的灰度：序号越大越深。 */
internal func bulletRangeColor(index: Int64): String {
    let shades = ["#efefef", "#e0e0e0", "#d0d0d0", "#c0c0c0", "#b0b0b0", "#a0a0a0"]
    shades[index % shades.size]
}
