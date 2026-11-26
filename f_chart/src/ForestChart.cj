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

/** 森林图一行：标签、估计值与置信区间。 */
internal class ForestRow {
    let label: String
    let estimate: Float64
    let lower: Float64
    let upper: Float64
    let weight: Option<Float64>

    init(
        label: String,
        estimate: Float64,
        lower: Float64,
        upper: Float64,
        weight: Option<Float64>
    ) {
        this.label = label
        this.estimate = estimate
        this.lower = lower
        this.upper = upper
        this.weight = weight
    }
}

/** M50 森林图。 */
public class ForestChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "forest")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "森林图仅支持 1 个系列")
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
        let rows = ArrayList<ForestRow>()
        var maxWeight = 0.0
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {label, estimate, lower, upper} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let label = json.requiredString("label")
            let estimate = jsonNumberValue(json.required("estimate"), "${itemPath}.estimate")
            let lower = jsonNumberValue(json.required("lower"), "${itemPath}.lower")
            let upper = jsonNumberValue(json.required("upper"), "${itemPath}.upper")
            if (lower > estimate) {
                throw chartInvalidValue("${itemPath}.lower", "lower 必须不大于 estimate")
            }
            if (estimate > upper) {
                throw chartInvalidValue("${itemPath}.estimate", "estimate 必须不大于 upper")
            }
            let weight = json.number("weight")
            match (weight) {
                case Some(value) =>
                    if (value < 0.0) {
                        throw chartInvalidValue("${itemPath}.weight", "权重不能为负")
                    }
                    maxWeight = maxFloat(maxWeight, value)
                case None => ()
            }
            rows.add(ForestRow(label, estimate, lower, upper, weight))
            index++
        }
        if (!config.yAxis.labels.isEmpty() && config.yAxis.labels.size != rows.size) {
            throw chartInvalidValue(
                "yAxis.labels",
                "标签长度 ${config.yAxis.labels.size} 与数据长度 ${rows.size} 不一致"
            )
        }

        let isLog = config.xAxis.axisType == "log"
        var dataMin = rows[0].lower
        var dataMax = rows[0].upper
        for (row in rows) {
            dataMin = minFloat(dataMin, row.lower)
            dataMax = maxFloat(dataMax, row.upper)
        }
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => dataMin
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => dataMax
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        if (isLog && (xMin <= 0.0 || dataMin <= 0.0)) {
            throw chartInvalidValue("xAxis.min", "对数轴的区间端点必须大于 0")
        }
        let nullLine = root.number("nullLine", default: 1.0)
        if (isLog && nullLine <= 0.0) {
            throw chartInvalidValue("nullLine", "对数轴的无效线必须大于 0")
        }
        let ticks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else if (isLog) {
            forestLogTicks(xMin, xMax, config.xAxis.logBase)
        } else {
            chartNiceTicks(xMin, xMax, config.xAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        let tickPositions = ArrayList<Float64>()
        for (tick in ticks) {
            tickPositions.add(position(tick, xMin, xMax, isLog))
            tickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
        var maxLabelWidth = 0.0
        for (row in rows) {
            let width = chartTextWidth(row.label, config.theme.fontSize)
            if (width > maxLabelWidth) {
                maxLabelWidth = width
            }
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxLabelWidth + 12.0, xLabelHeight)
        let color = match (seriesColor) {
            case Some(value) => value
            case None => config.theme.colorAt(0)
        }
        let rowHeight = frame.plot.height / Float64(rows.size)

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

        let unitScale = LinearScale(0.0, 1.0, frame.plot.x, frame.plot.right())
        let nullX = unitScale.scale(position(nullLine, xMin, xMax, isLog))
        kit.line(
            nullX, frame.plot.y, nullX, frame.plot.bottom(),
            stroke: config.theme.axisColor, strokeWidth: 1.0,
            className: "forest-null", dash: "5 4"
        )

        for (rowIndex in 0..rows.size) {
            let row = rows[rowIndex]
            let centerY = frame.plot.y + (Float64(rowIndex) + 0.5) * rowHeight
            let lowX = unitScale.scale(position(row.lower, xMin, xMax, isLog))
            let highX = unitScale.scale(position(row.upper, xMin, xMax, isLog))
            let estimateX = unitScale.scale(position(row.estimate, xMin, xMax, isLog))
            kit.line(
                lowX, centerY, highX, centerY,
                stroke: color, strokeWidth: 1.5, className: "forest-ci"
            )
            let size = match (row.weight) {
                case Some(value) => forestMarkerSize(value, maxWeight)
                case None => 8.0
            }
            kit.rect(
                estimateX - size / 2.0, centerY - size / 2.0, size, size,
                fill: color, className: "forest-point"
            )
            kit.text(
                frame.plot.x - 8.0, centerY, row.label,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "tick-label"
            )
        }
        frame.drawXAxisNumeric(kit, tickPositions.toArray(), unitScale, tickLabels.toArray())
        builder.toSvgString()
    }

    private func position(value: Float64, minValue: Float64, maxValue: Float64, isLog: Bool): Float64 {
        if (isLog) {
            forestLogPosition(value, minValue, maxValue)
        } else {
            (value - minValue) / (maxValue - minValue)
        }
    }
}

/** 对数轴归一化位置：`log(value)` 在 `[log(min), log(max)]` 内的比例。 */
internal func forestLogPosition(value: Float64, minValue: Float64, maxValue: Float64): Float64 {
    (log(value) - log(minValue)) / (log(maxValue) - log(minValue))
}

/** 对数刻度：范围内各整数次幂，补上端点。 */
internal func forestLogTicks(minValue: Float64, maxValue: Float64, base: Float64): Array<Float64> {
    if (minValue <= 0.0 || maxValue <= minValue || base <= 1.0) {
        return [minValue, maxValue]
    }
    let ticks = ArrayList<Float64>()
    ticks.add(minValue)
    let start = Int64(ceil(log(minValue) / log(base)))
    let stop = Int64(floor(log(maxValue) / log(base)))
    var exponent = start
    while (exponent <= stop) {
        let value = pow(base, Float64(exponent))
        if (value > minValue * 1.0000001 && value < maxValue * 0.9999999) {
            ticks.add(value)
        }
        exponent++
    }
    ticks.add(maxValue)
    ticks.toArray()
}

/** 权重 → 方块边长：0 → 6，最大 → 14。 */
internal func forestMarkerSize(weight: Float64, maxWeight: Float64): Float64 {
    if (maxWeight <= 0.0) {
        return 8.0
    }
    if (weight <= 0.0) {
        return 6.0
    }
    let ratio = minFloat(weight / maxWeight, 1.0)
    6.0 + 8.0 * sqrt(ratio)
}
