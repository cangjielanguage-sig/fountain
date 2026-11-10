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

/** Bland-Altman 图的一个测量对。 */
internal class BlandAltmanPair {
    let mean: Float64
    let diff: Float64

    init(mean: Float64, diff: Float64) {
        this.mean = mean
        this.diff = diff
    }
}

/** M91 Bland-Altman 图。 */
public class BlandAltmanChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "bland-altman")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "Bland-Altman 图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let pairs = ArrayList<BlandAltmanPair>()
        let rawPairs = ArrayList<Array<Float64>>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = bulletNumber(json, "x", itemPath)
            let y = bulletNumber(json, "y", itemPath)
            pairs.add(BlandAltmanPair((x + y) / 2.0, y - x))
            rawPairs.add([x, y])
            itemIndex++
        }
        let pairArray = pairs.toArray()
        let stats = blandAltmanStats(rawPairs.toArray())

        var meanMin = pairArray[0].mean
        var meanMax = meanMin
        var diffMin = minFloat(stats[1], pairArray[0].diff)
        var diffMax = maxFloat(stats[2], pairArray[0].diff)
        for (pair in pairArray) {
            meanMin = minFloat(meanMin, pair.mean)
            meanMax = maxFloat(meanMax, pair.mean)
            diffMin = minFloat(diffMin, pair.diff)
            diffMax = maxFloat(diffMax, pair.diff)
        }
        var meanSpan = meanMax - meanMin
        if (meanSpan <= 0.0) {
            meanSpan = 1.0
        }
        var diffSpan = diffMax - diffMin
        if (diffSpan <= 0.0) {
            diffSpan = 1.0
        }
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => meanMin - meanSpan * 0.05
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => meanMax + meanSpan * 0.05
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => diffMin - diffSpan * 0.08
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => diffMax + diffSpan * 0.08
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xMin, xMax, config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            maxYLabelWidth = maxFloat(
                maxYLabelWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let legendVisible = config.legend.show && !seriesName.isEmpty()
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight,
            rightLabelWidth: 52.0
        )
        let xScale = LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())
        let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)

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

        drawLimit(
            kit, config, frame.plot, yScale.scale(stats[0]), stats[0],
            "#4caf50", "bland-altman-mean", "均值"
        )
        drawLimit(
            kit, config, frame.plot, yScale.scale(stats[1]), stats[1],
            "#e53935", "bland-altman-limit", "下限"
        )
        drawLimit(
            kit, config, frame.plot, yScale.scale(stats[2]), stats[2],
            "#e53935", "bland-altman-limit", "上限"
        )

        let pointColor = config.theme.colorAt(0)
        for (pair in pairArray) {
            kit.circle(
                xScale.scale(pair.mean),
                yScale.scale(pair.diff),
                3.5,
                fill: pointColor,
                className: "bland-altman-point"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func drawLimit(
        kit: ChartSvgKit,
        config: ChartConfig,
        plot: ChartRect,
        y: Float64,
        value: Float64,
        color: String,
        className: String,
        label: String
    ): Unit {
        kit.line(
            plot.x, y, plot.right(), y,
            stroke: color, strokeWidth: 1.0, className: className, dash: "6 4"
        )
        kit.text(
            plot.right() + 6.0, y,
            "${label} ${chartFormatTick(value, config.yAxis.labelFormat)}",
            size: config.theme.fontSize - 1.0,
            color: color,
            className: "bland-altman-label"
        )
    }
}

/** 返回 `[均值差, 下限, 上限]`，界限为 `均值 ± 1.96 × 样本标准差`。 */
internal func blandAltmanStats(pairs: Array<Array<Float64>>): Array<Float64> {
    if (pairs.isEmpty()) {
        return [0.0, 0.0, 0.0]
    }
    let diffs = ArrayList<Float64>()
    var sum = 0.0
    for (pair in pairs) {
        let diff = pair[1] - pair[0]
        diffs.add(diff)
        sum += diff
    }
    let count = diffs.size
    let mean = sum / Float64(count)
    var variance = 0.0
    if (count > 1) {
        for (diff in diffs) {
            variance += (diff - mean) * (diff - mean)
        }
        variance = variance / Float64(count - 1)
    }
    let sd = sqrt(variance)
    [mean, mean - 1.96 * sd, mean + 1.96 * sd]
}
