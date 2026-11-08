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

/** 控制限：中心线、上限、下限。 */
internal class ControlLimits {
    let center: Float64
    let ucl: Float64
    let lcl: Float64

    init(center: Float64, ucl: Float64, lcl: Float64) {
        this.center = center
        this.ucl = ucl
        this.lcl = lcl
    }
}

/** M38 控制图：过程测量值、中心线与上下控制限。 */
public class ControlChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "control")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "控制图仅支持 1 个系列")
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
            values.add(jsonNumberValue(item, itemPath))
            index++
        }
        let numberArray = values.toArray()
        let limits = resolveControlLimits(
            numberArray,
            seriesJson.number("center"),
            seriesJson.number("ucl"),
            seriesJson.number("lcl"),
            seriesJson.number("sigma")
        )

        let labels = config.xAxis.labels
        if (!labels.isEmpty() && labels.size != numberArray.size) {
            throw chartInvalidValue(
                "xAxis.labels",
                "标签长度 ${labels.size} 与数据长度 ${numberArray.size} 不一致"
            )
        }
        let categoryLabels = ArrayList<String>()
        for (position in 0..numberArray.size) {
            categoryLabels.add(if (position < labels.size) {
                labels[position]
            } else {
                (position + 1).toString()
            })
        }

        var dataMin = minFloat(limits.lcl, limits.center)
        var dataMax = maxFloat(limits.ucl, limits.center)
        for (value in numberArray) {
            dataMin = minFloat(dataMin, value)
            dataMax = maxFloat(dataMax, value)
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
            rightLabelWidth: 58.0
        )
        let band = BandScale(frame.plot.x, frame.plot.right(), numberArray.size)
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

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [config.theme.colorAt(0)]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let lineColor = config.theme.colorAt(0)
        let limitColor = "#e53935"
        let centerColor = "#4caf50"
        drawLimitLine(
            kit, frame.plot.x, frame.plot.right(), yScale.scale(limits.ucl),
            limitColor, "control-ucl", "UCL", limits.ucl, config, frame.plot.right()
        )
        drawLimitLine(
            kit, frame.plot.x, frame.plot.right(), yScale.scale(limits.center),
            centerColor, "control-center", "CL", limits.center, config, frame.plot.right()
        )
        drawLimitLine(
            kit, frame.plot.x, frame.plot.right(), yScale.scale(limits.lcl),
            limitColor, "control-lcl", "LCL", limits.lcl, config, frame.plot.right()
        )

        let path = StringBuilder()
        for (position in 0..numberArray.size) {
            let x = band.center(position)
            let y = yScale.scale(numberArray[position])
            if (position == 0) {
                path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            } else {
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            }
        }
        kit.path(
            path.toString(), fill: "none", stroke: lineColor, strokeWidth: 2.0,
            className: "control-line"
        )
        for (position in 0..numberArray.size) {
            let value = numberArray[position]
            let x = band.center(position)
            let y = yScale.scale(value)
            if (value < limits.lcl || value > limits.ucl) {
                kit.circle(x, y, 4.0, fill: limitColor, className: "control-outlier")
            } else {
                kit.circle(x, y, 3.5, fill: lineColor, className: "control-point")
            }
        }
        frame.drawXAxis(kit, categoryLabels.toArray(), band)
        builder.toSvgString()
    }

    private func drawLimitLine(
        kit: ChartSvgKit,
        left: Float64,
        right: Float64,
        y: Float64,
        color: String,
        className: String,
        label: String,
        value: Float64,
        config: ChartConfig,
        labelX: Float64
    ): Unit {
        kit.line(
            left, y, right, y,
            stroke: color, strokeWidth: 1.0, className: className, dash: "6 4"
        )
        kit.text(
            labelX + 6.0, y,
            "${label} ${chartFormatTick(value, config.yAxis.labelFormat)}",
            size: config.theme.fontSize,
            color: color,
            className: "control-label"
        )
    }
}

/** 算术均值。 */
internal func controlMean(values: Array<Float64>): Float64 {
    if (values.isEmpty()) {
        throw chartInvalidValue("series[0].data", "数据不能为空")
    }
    var total = 0.0
    for (value in values) {
        total += value
    }
    total / Float64(values.size)
}

/** 样本标准差（分母 n−1）；样本不足 2 个时为 0。 */
internal func controlStdDev(values: Array<Float64>): Float64 {
    if (values.size < 2) {
        return 0.0
    }
    let mean = controlMean(values)
    var sum = 0.0
    for (value in values) {
        let deviation = value - mean
        sum += deviation * deviation
    }
    sqrt(sum / Float64(values.size - 1))
}

/** 解析控制限：显式值优先，缺省用均值与 ±3σ。 */
internal func resolveControlLimits(
    values: Array<Float64>,
    center: Option<Float64>,
    ucl: Option<Float64>,
    lcl: Option<Float64>,
    sigma: Option<Float64>
): ControlLimits {
    let mean = controlMean(values)
    let centerValue = match (center) {
        case Some(value) => value
        case None => mean
    }
    let sigmaValue = match (sigma) {
        case Some(value) =>
            if (value < 0.0) {
                throw chartInvalidValue("series[0].sigma", "sigma 不能为负")
            }
            value
        case None => controlStdDev(values)
    }
    let uclValue = match (ucl) {
        case Some(value) => value
        case None => centerValue + 3.0 * sigmaValue
    }
    let lclValue = match (lcl) {
        case Some(value) => value
        case None => centerValue - 3.0 * sigmaValue
    }
    if (uclValue < lclValue) {
        throw chartInvalidValue("series[0].ucl", "ucl 必须不小于 lcl")
    }
    ControlLimits(centerValue, uclValue, lclValue)
}
