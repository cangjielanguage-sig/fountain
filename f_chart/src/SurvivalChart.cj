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

/** 生存曲线数据点。 */
internal class SurvivalPoint {
    let time: Float64
    let survival: Float64
    let censored: Bool

    init(time: Float64, survival: Float64, censored: Bool) {
        this.time = time
        this.survival = survival
        this.censored = censored
    }
}

/** 生存曲线系列。 */
internal class SurvivalSeries {
    let name: String
    let color: ?String
    let points: Array<SurvivalPoint>

    init(name: String, color: ?String, points: Array<SurvivalPoint>) {
        this.name = name
        this.color = color
        this.points = points
    }
}

/** M49 Kaplan-Meier 生存曲线。 */
public class SurvivalChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "survival")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<SurvivalSeries>()
        var seriesIndex = 0
        for (item in seriesItems) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let color = json.string("color")
            let dataArray = json.requiredArray("data")
            let items = dataArray.getItems()
            if (items.isEmpty()) {
                throw chartInvalidValue("${path}.data", "数据不能为空")
            }
            let points = ArrayList<SurvivalPoint>()
            var pointIndex = 0
            for (pointItem in items) {
                let pointPath = "${path}.data[${pointIndex}]"
                if (!pointItem.kind.isObject) {
                    throw chartInvalidValue(pointPath, "期望 {time, survival} 对象")
                }
                let pointJson = ChartJson.of(pointItem.asObject(), pointPath)
                let time = jsonNumberValue(pointJson.required("time"), "${pointPath}.time")
                let survival = jsonNumberValue(
                    pointJson.required("survival"), "${pointPath}.survival"
                )
                if (time < 0.0) {
                    throw chartInvalidValue("${pointPath}.time", "时间不能为负")
                }
                if (survival < 0.0 || survival > 1.0) {
                    throw chartInvalidValue("${pointPath}.survival", "生存率必须在 0–1 之间")
                }
                let censored = pointJson.bool("censored", default: false)
                points.add(SurvivalPoint(time, survival, censored))
                pointIndex++
            }
            seriesList.add(SurvivalSeries(name, color, sortPoints(points)))
            seriesIndex++
        }
        let confidence = root.bool("confidence", default: false)
        let showCensors = root.bool("showCensors", default: true)

        var maxTime = 0.0
        for (series in seriesList) {
            maxTime = maxFloat(maxTime, series.points[series.points.size - 1].time)
        }
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => if (maxTime > xMin) { maxTime * 1.02 } else { xMin + 1.0 }
        }
        if (xMax <= xMin) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => 0.0
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => 1.0
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
        let xLabels = ArrayList<String>()
        for (tick in xTicks) {
            xLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        var legendVisible = false
        for (series in seriesList) {
            if (!series.name.isEmpty()) {
                legendVisible = true
            }
        }
        legendVisible = legendVisible && config.legend.show
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
        let xScale = LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())
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

        let legendNames = ArrayList<String>()
        let legendColors = ArrayList<String>()
        for (index in 0..seriesList.size) {
            if (!seriesList[index].name.isEmpty()) {
                legendNames.add(seriesList[index].name)
                legendColors.add(colorOf(seriesList[index], index, config))
            }
        }
        frame.drawLegend(kit, legendNames.toArray(), legendColors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        if (confidence) {
            for (bandIndex in 0..seriesList.size) {
                let series = seriesList[bandIndex]
                let path = StringBuilder()
                let count = Int64(series.points.size)
                for (index in 0..series.points.size) {
                    let bounds = survivalConfidence(series.points[index].survival, count)
                    let x = xScale.scale(series.points[index].time)
                    let y = yScale.scale(bounds[1])
                    if (index == 0) {
                        path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    } else {
                        path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    }
                }
                var reverse = series.points.size - 1
                while (reverse >= 0) {
                    let bounds = survivalConfidence(series.points[reverse].survival, count)
                    let x = xScale.scale(series.points[reverse].time)
                    let y = yScale.scale(bounds[0])
                    path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    reverse--
                }
                path.append(" Z")
                kit.path(
                    path.toString(),
                    fill: colorOf(series, bandIndex, config),
                    className: "survival-band",
                    fillOpacity: 0.15
                )
            }
        }

        for (index in 0..seriesList.size) {
            let series = seriesList[index]
            let color = colorOf(series, index, config)
            let path = StringBuilder()
            path.append(
                "M ${formatSvgNumber(xScale.scale(series.points[0].time))} " +
                "${formatSvgNumber(yScale.scale(series.points[0].survival))}"
            )
            for (pointIndex in 1..series.points.size) {
                let previous = series.points[pointIndex - 1]
                let current = series.points[pointIndex]
                path.append(
                    " L ${formatSvgNumber(xScale.scale(current.time))} " +
                    "${formatSvgNumber(yScale.scale(previous.survival))}"
                )
                path.append(
                    " L ${formatSvgNumber(xScale.scale(current.time))} " +
                    "${formatSvgNumber(yScale.scale(current.survival))}"
                )
            }
            kit.path(
                path.toString(), fill: "none", stroke: color, strokeWidth: 2.0,
                className: "survival-line"
            )
            for (point in series.points) {
                let x = xScale.scale(point.time)
                let y = yScale.scale(point.survival)
                kit.circle(x, y, 2.5, fill: color, className: "survival-point")
                if (showCensors && point.censored) {
                    kit.text(
                        x, y - 6.0, "+",
                        size: config.theme.fontSize + 2.0,
                        color: color,
                        anchor: "middle",
                        className: "survival-censor"
                    )
                }
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xLabels.toArray())
        builder.toSvgString()
    }

    private func colorOf(series: SurvivalSeries, index: Int64, config: ChartConfig): String {
        match (series.color) {
            case Some(value) => value
            case None => config.theme.colorAt(index)
        }
    }

    private func sortPoints(points: ArrayList<SurvivalPoint>): Array<SurvivalPoint> {
        let sorted = ArrayList<SurvivalPoint>()
        for (point in points) {
            sorted.add(point)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && sorted[j].time < sorted[j - 1].time) {
                let temporary = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = temporary
                j--
            }
        }
        sorted.toArray()
    }
}

/** 二项近似置信区间 `[下界, 上界]`，夹到 0–1。 */
internal func survivalConfidence(survival: Float64, count: Int64): Array<Float64> {
    if (count <= 0) {
        return [0.0, 1.0]
    }
    var value = survival
    if (value < 0.0) {
        value = 0.0
    }
    if (value > 1.0) {
        value = 1.0
    }
    let standardError = sqrt(value * (1.0 - value) / Float64(count))
    let margin = 1.96 * standardError
    [maxFloat(0.0, value - margin), minFloat(1.0, value + margin)]
}
