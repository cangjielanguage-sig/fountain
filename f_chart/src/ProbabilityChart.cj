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

/**
 * M42 概率图。
 *
 * 样本分位数对理论分位数作散点，并用最小二乘参考线辅助判断分布假设。
 */
public class ProbabilityChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "probability")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "概率图仅支持 1 个系列")
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
        let distribution = seriesJson.string("distribution", default: "normal")
        if (distribution != "normal" && distribution != "uniform" && distribution != "exponential") {
            throw chartInvalidValue(
                "series[0].distribution",
                "期望 normal / uniform / exponential"
            )
        }
        let showLine = seriesJson.bool("showLine", default: true)

        let sorted = sortValues(values.toArray())
        let theory = qqTheoryQuantiles(sorted.size, distribution)
        let xRange = resolveRange(config.xAxis, theory[0], theory[theory.size - 1], "xAxis.min")
        let yRange = resolveRange(
            config.yAxis, sorted[0], sorted[sorted.size - 1], "yAxis.min"
        )
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
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

        if (showLine) {
            let fit = qqFitLine(theory, sorted)
            let startX = xScale.scale(xRange[0])
            let endX = xScale.scale(xRange[1])
            let startY = yScale.scale(fit[0] + fit[1] * xRange[0])
            let endY = yScale.scale(fit[0] + fit[1] * xRange[1])
            kit.line(
                startX, startY, endX, endY,
                stroke: color, strokeWidth: 1.5, className: "probability-line", dash: "4 4"
            )
        }
        for (pointIndex in 0..sorted.size) {
            kit.circle(
                xScale.scale(theory[pointIndex]),
                yScale.scale(sorted[pointIndex]),
                3.5,
                fill: color,
                className: "probability-point"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
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

    private func resolveRange(
        axis: ChartAxis,
        dataMin: Float64,
        dataMax: Float64,
        path: String
    ): Array<Float64> {
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
            throw chartInvalidValue(path, "轴范围必须递增")
        }
        [minimum, maximum]
    }
}
