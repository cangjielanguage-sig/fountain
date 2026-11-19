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
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

/** ROC 工作点。 */
internal class RocPoint {
    let x: Float64
    let y: Float64

    init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

/** M47 ROC 曲线。 */
public class RocChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "roc")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "ROC 图仅支持 1 个系列")
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
        let points = ArrayList<RocPoint>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x, y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = jsonNumberValue(json.required("x"), "${itemPath}.x")
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            if (x < 0.0 || x > 1.0) {
                throw chartInvalidValue("${itemPath}.x", "假阳性率必须在 0–1 之间")
            }
            if (y < 0.0 || y > 1.0) {
                throw chartInvalidValue("${itemPath}.y", "真阳性率必须在 0–1 之间")
            }
            points.add(RocPoint(x, y))
            index++
        }
        let sorted = sortPoints(points)
        let auc = seriesJson.number("auc")
        match (auc) {
            case Some(value) =>
                if (value < 0.0 || value > 1.0) {
                    throw chartInvalidValue("series[0].auc", "AUC 必须在 0–1 之间")
                }
            case None => ()
        }
        let diagonal = root.bool("diagonal", default: true)

        let xRange = resolveRange(config.xAxis, 0.0, 1.0, "xAxis.min")
        let yRange = resolveRange(config.yAxis, 0.0, 1.0, "yAxis.min")
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
        let xLabels = ArrayList<String>()
        for (tick in xTicks) {
            xLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
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
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.x, frame.plot.right())
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

        if (diagonal) {
            kit.line(
                xScale.scale(xRange[0]), yScale.scale(xRange[0]),
                xScale.scale(xRange[1]), yScale.scale(xRange[1]),
                stroke: config.theme.axisColor, strokeWidth: 1.0,
                className: "roc-diagonal", dash: "4 4"
            )
        }
        let path = StringBuilder()
        for (position in 0..sorted.size) {
            let x = xScale.scale(sorted[position].x)
            let y = yScale.scale(sorted[position].y)
            if (position == 0) {
                path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            } else {
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            }
        }
        kit.path(
            path.toString(), fill: "none", stroke: color, strokeWidth: 2.0,
            className: "roc-line"
        )
        for (point in sorted) {
            kit.circle(
                xScale.scale(point.x), yScale.scale(point.y), 3.0,
                fill: color, className: "roc-point"
            )
        }
        match (auc) {
            case Some(value) =>
                kit.text(
                    frame.plot.x + 8.0, frame.plot.y + 14.0,
                    "AUC = ${chartFormatTick(value, "{value}")}",
                    size: config.theme.fontSize,
                    color: color,
                    className: "roc-auc"
                )
            case None => ()
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xLabels.toArray())
        builder.toSvgString()
    }

    private func sortPoints(points: ArrayList<RocPoint>): Array<RocPoint> {
        let sorted = ArrayList<RocPoint>()
        for (point in points) {
            sorted.add(point)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && sorted[j].x < sorted[j - 1].x) {
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
        defaultMin: Float64,
        defaultMax: Float64,
        path: String
    ): Array<Float64> {
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => defaultMin
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => defaultMax
        }
        if (maximum <= minimum) {
            throw chartInvalidValue(path, "轴范围必须递增")
        }
        [minimum, maximum]
    }
}
