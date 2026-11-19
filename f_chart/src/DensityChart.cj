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

/** 核密度图的一个系列。 */
internal class DensitySeries {
    let name: String
    let values: Array<Float64>
    let color: ?String
    let bandwidth: ?Float64
    let fill: Bool

    init(name: String, values: Array<Float64>, color: ?String, bandwidth: ?Float64, fill: Bool) {
        this.name = name
        this.values = values
        this.color = color
        this.bandwidth = bandwidth
        this.fill = fill
    }
}

/**
 * M18 核密度图。
 *
 * 用高斯核平滑估计分布密度；支持多系列叠加与填充。
 */
public class DensityChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "density")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }

        let series = ArrayList<DensitySeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let dataArray = json.requiredArray("data")
            let items = dataArray.getItems()
            if (items.isEmpty()) {
                throw chartInvalidValue("${path}.data", "数据不能为空")
            }
            let values = ArrayList<Float64>()
            var valueIndex = 0
            for (entry in items) {
                let itemPath = "${path}.data[${valueIndex}]"
                if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                    throw chartInvalidValue(itemPath, "期望数字")
                }
                values.add(jsonNumberValue(entry, itemPath))
                valueIndex++
            }
            let bandwidth = match (json.number("bandwidth")) {
                case Some(value) =>
                    if (value <= 0.0 || value.isNaN() || value.isInf()) {
                        throw chartInvalidValue("${path}.bandwidth", "带宽必须大于 0")
                    }
                    Some(value)
                case None => None<Float64>
            }
            let color = json.string("color")
            let fill = json.bool("fill", default: false)
            series.add(DensitySeries(name, values.toArray(), color, bandwidth, fill))
            seriesIndex++
        }

        let bandwidths = ArrayList<Float64>()
        for (item in series) {
            bandwidths.add(match (item.bandwidth) {
                case Some(value) => value
                case None => defaultBandwidth(item.values)
            })
        }

        var xMin = 0.0
        var xMax = 1.0
        var hasRange = false
        for (index in 0..series.size) {
            let item = series[index]
            var dataMin = item.values[0]
            var dataMax = item.values[0]
            for (value in item.values) {
                dataMin = minFloat(dataMin, value)
                dataMax = maxFloat(dataMax, value)
            }
            let margin = bandwidths[index] * 3.0
            let left = dataMin - margin
            let right = dataMax + margin
            if (!hasRange) {
                xMin = left
                xMax = right
                hasRange = true
            } else {
                xMin = minFloat(xMin, left)
                xMax = maxFloat(xMax, right)
            }
        }
        if (xMax <= xMin) {
            xMax = xMin + 1.0
        }
        xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => xMin
        }
        xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => xMax
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }

        var maxDensity = 0.0
        for (index in 0..series.size) {
            let item = series[index]
            let bandwidth = bandwidths[index]
            for (step in 0..=100) {
                let x = xMin + (xMax - xMin) * Float64(step) / 100.0
                let density = gaussianKde(item.values, bandwidth, x)
                if (density > maxDensity) {
                    maxDensity = density
                }
            }
        }
        if (maxDensity <= 0.0) {
            maxDensity = 1.0
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => maxDensity * 1.05
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xMin, xMax, config.xAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show &&
            !(series.size == 1 && series[0].name.isEmpty())
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
        let xScale = LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)
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
        for (index in 0..series.size) {
            names.add(series[index].name)
            colors.add(match (series[index].color) {
                case Some(color) => color
                case None => config.theme.colorAt(index)
            })
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        for (index in 0..series.size) {
            let item = series[index]
            let color = colors[index]
            drawDensity(kit, item, bandwidths[index], color, xScale, yScale, frame.plot.bottom())
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func drawDensity(
        kit: ChartSvgKit,
        series: DensitySeries,
        bandwidth: Float64,
        color: String,
        xScale: LinearScale,
        yScale: LinearScale,
        baseline: Float64
    ): Unit {
        let xs = ArrayList<Float64>()
        let ys = ArrayList<Float64>()
        for (step in 0..=100) {
            let x = xScale.minValue + (xScale.maxValue - xScale.minValue) * Float64(step) / 100.0
            xs.add(xScale.scale(x))
            ys.add(yScale.scale(gaussianKde(series.values, bandwidth, x)))
        }
        if (series.fill) {
            let area = StringBuilder()
            area.append("M ${formatSvgNumber(xs[0])} ${formatSvgNumber(baseline)}")
            for (index in 0..xs.size) {
                area.append(" L ${formatSvgNumber(xs[index])} ${formatSvgNumber(ys[index])}")
            }
            area.append(" L ${formatSvgNumber(xs[xs.size - 1])} ${formatSvgNumber(baseline)} Z")
            kit.path(
                area.toString(), fill: color, className: "density-area", fillOpacity: 0.25
            )
        }
        let line = StringBuilder()
        line.append("M ${formatSvgNumber(xs[0])} ${formatSvgNumber(ys[0])}")
        for (index in 1..xs.size) {
            line.append(" L ${formatSvgNumber(xs[index])} ${formatSvgNumber(ys[index])}")
        }
        kit.path(
            line.toString(), fill: "none", stroke: color, strokeWidth: 2.0, className: "density-line"
        )
    }
}

/** 高斯核密度估计。 */
internal func gaussianKde(values: Array<Float64>, bandwidth: Float64, x: Float64): Float64 {
    if (values.isEmpty() || bandwidth <= 0.0) {
        return 0.0
    }
    var total = 0.0
    for (value in values) {
        let z = (x - value) / bandwidth
        total += exp(-0.5 * z * z)
    }
    let normalizer = Float64(values.size) * bandwidth * sqrt(2.0 * 3.141592653589793)
    total / normalizer
}

/** Silverman 经验带宽；退化时返回 1。 */
internal func defaultBandwidth(values: Array<Float64>): Float64 {
    if (values.size < 2) {
        return 1.0
    }
    var sum = 0.0
    for (value in values) {
        sum += value
    }
    let mean = sum / Float64(values.size)
    var variance = 0.0
    for (value in values) {
        let delta = value - mean
        variance += delta * delta
    }
    variance /= Float64(values.size - 1)
    let deviation = sqrt(variance)
    let bandwidth = 1.06 * deviation * pow(Float64(values.size), -0.2)
    if (bandwidth <= 0.0 || bandwidth.isNaN() || bandwidth.isInf()) {
        1.0
    } else {
        bandwidth
    }
}
