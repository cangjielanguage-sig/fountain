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

/** M96 校准曲线。 */
public class CalibrationChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "calibration")
        let root = ChartJson.of(data)
        let diagonal = root.bool("diagonal", default: true)
        match (root.number("binCount")) {
            case Some(value) =>
                if (value < 1.0 || value != floor(value)) {
                    throw chartInvalidValue("binCount", "分箱数必须为正整数")
                }
            case None => ()
        }
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "校准曲线仅支持 1 个系列")
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
        let raw = ArrayList<Array<Float64>>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = volcanoNumber(json, "x", itemPath)
            let y = volcanoNumber(json, "y", itemPath)
            raw.add([x, y])
            itemIndex++
        }
        let points = sortLiftPoints(raw.toArray())

        var dataMin = minFloat(points[0][0], points[0][1])
        var dataMax = maxFloat(points[0][0], points[0][1])
        for (point in points) {
            dataMin = minFloat(dataMin, minFloat(point[0], point[1]))
            dataMax = maxFloat(dataMax, maxFloat(point[0], point[1]))
        }
        let rangeMin = minFloat(0.0, dataMin)
        let rangeMax = maxFloat(1.0, dataMax)
        let xMin = match (config.xAxis.min) {
            case Some(value) => value
            case None => rangeMin
        }
        let xMax = match (config.xAxis.max) {
            case Some(value) => value
            case None => rangeMax
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => rangeMin
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => rangeMax
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
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
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

        if (diagonal) {
            kit.line(
                xScale.scale(xMin), yScale.scale(yMin),
                xScale.scale(xMax), yScale.scale(yMax),
                stroke: "#9e9e9e", strokeWidth: 1.0,
                className: "calibration-diagonal", dash: "6 4"
            )
        }

        let color = config.theme.colorAt(0)
        let path = StringBuilder()
        for (index in 0..points.size) {
            let x = xScale.scale(points[index][0])
            let y = yScale.scale(points[index][1])
            if (index == 0) {
                path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            } else {
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            }
        }
        kit.path(
            path.toString(),
            fill: "none",
            stroke: color,
            strokeWidth: 2.0,
            className: "calibration-line"
        )
        for (point in points) {
            kit.circle(
                xScale.scale(point[0]),
                yScale.scale(point[1]),
                3.5,
                fill: color,
                className: "calibration-point"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}
