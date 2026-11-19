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

/** 直方图分箱结果。 */
internal class HistogramBins {
    let minimum: Float64
    let maximum: Float64
    let counts: Array<Int64>

    init(minimum: Float64, maximum: Float64, counts: Array<Int64>) {
        this.minimum = minimum
        this.maximum = maximum
        this.counts = counts
    }

    func width(): Float64 {
        (this.maximum - this.minimum) / Float64(this.counts.size)
    }
}

/**
 * M17 直方图。
 *
 * `series[0].data` 为数值数组，按 `bins` 等宽分箱并绘制频数柱。
 */
public class HistogramChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "histogram")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "直方图仅支持 1 个系列")
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

        let binCount = resolveBinCount(seriesJson, values.size)
        let bins = computeHistogram(values.toArray(), binCount)
        let xRange = resolveXRange(config.xAxis, bins)
        let maxCount = maxInt(bins.counts)
        let yRange = resolveYRange(config.yAxis, maxCount)
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
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
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)
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

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [match (seriesColor) {
                case Some(value) => value
                case None => config.theme.colorAt(0)
            }]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let color = match (seriesColor) {
            case Some(value) => value
            case None => config.theme.colorAt(0)
        }
        let width = bins.width()
        for (position in 0..bins.counts.size) {
            let frequency = bins.counts[position]
            if (frequency <= 0) {
                continue
            }
            let startValue = bins.minimum + width * Float64(position)
            let endValue = startValue + width
            let left = xScale.scale(startValue)
            let right = xScale.scale(endValue)
            let top = yScale.scale(Float64(frequency))
            kit.rect(
                left, top, right - left, frame.plot.bottom() - top,
                fill: color, className: "histogram-bar", fillOpacity: 0.85
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func resolveBinCount(seriesJson: ChartJson, sampleSize: Int64): Int64 {
        match (seriesJson.value("bins")) {
            case Some(value) =>
                if (!(value.kind.isInt || value.kind.isDecimal)) {
                    throw chartInvalidValue("series[0].bins", "期望正整数")
                }
                let raw = jsonNumberValue(value, "series[0].bins")
                if (raw < 1.0 || raw != floor(raw)) {
                    throw chartInvalidValue("series[0].bins", "分箱数必须为正整数")
                }
                Int64(raw)
            case None =>
                let approx = Int64(sqrt(Float64(sampleSize)))
                if (approx < 1) {
                    1
                } else {
                    approx
                }
        }
    }

    private func resolveXRange(axis: ChartAxis, bins: HistogramBins): Array<Float64> {
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => bins.minimum
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => bins.maximum
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        [minimum, maximum]
    }

    private func resolveYRange(axis: ChartAxis, maxCount: Int64): Array<Float64> {
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => if (maxCount > 0) { Float64(maxCount) * 1.05 } else { 1.0 }
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        [minimum, maximum]
    }

    private func maxInt(values: Array<Int64>): Int64 {
        var maximum = 0
        for (value in values) {
            if (value > maximum) {
                maximum = value
            }
        }
        maximum
    }
}

/** 等宽分箱统计频数；最大值归入最后一箱。 */
internal func computeHistogram(values: Array<Float64>, binCount: Int64): HistogramBins {
    if (values.isEmpty()) {
        throw chartInvalidValue("series[0].data", "数据不能为空")
    }
    if (binCount <= 0) {
        throw chartInvalidValue("series[0].bins", "分箱数必须为正整数")
    }
    var minimum = values[0]
    var maximum = values[0]
    for (value in values) {
        minimum = minFloat(minimum, value)
        maximum = maxFloat(maximum, value)
    }
    if (maximum == minimum) {
        minimum -= 0.5
        maximum += 0.5
    }
    let width = (maximum - minimum) / Float64(binCount)
    let counts = ArrayList<Int64>()
    for (_ in 0..binCount) {
        counts.add(0)
    }
    for (value in values) {
        var position = Int64(floor((value - minimum) / width))
        if (position < 0) {
            position = 0
        }
        if (position >= binCount) {
            position = binCount - 1
        }
        counts[position] = counts[position] + 1
    }
    HistogramBins(minimum, maximum, counts.toArray())
}
