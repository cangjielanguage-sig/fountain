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

/** 火山图的一个数据点。 */
internal class VolcanoPoint {
    let x: Float64
    let y: Float64
    let label: String

    init(x: Float64, y: Float64, label: String) {
        this.x = x
        this.y = y
        this.label = label
    }
}

/** M92 火山图。 */
public class VolcanoChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "volcano")
        let root = ChartJson.of(data)
        let foldChangeThreshold = root.number("foldChangeThreshold", default: 1.0)
        if (foldChangeThreshold < 0.0) {
            throw chartInvalidValue("foldChangeThreshold", "倍数变化阈值不能为负")
        }
        let pThreshold = root.number("pThreshold", default: 1.3)
        if (pThreshold < 0.0) {
            throw chartInvalidValue("pThreshold", "显著性阈值不能为负")
        }
        let upColor = root.string("upColor", default: "#e53935")
        let downColor = root.string("downColor", default: "#1e88e5")
        let neutralColor = "#9e9e9e"

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "火山图仅支持 1 个系列")
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
        let points = ArrayList<VolcanoPoint>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y,label?} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = volcanoNumber(json, "x", itemPath)
            let y = volcanoNumber(json, "y", itemPath)
            points.add(VolcanoPoint(x, y, json.string("label", default: "")))
            itemIndex++
        }
        let pointArray = points.toArray()

        var xMin = minFloat(-foldChangeThreshold, pointArray[0].x)
        var xMax = maxFloat(foldChangeThreshold, pointArray[0].x)
        var yMin = pointArray[0].y
        var yMax = maxFloat(pThreshold, pointArray[0].y)
        for (point in pointArray) {
            xMin = minFloat(xMin, point.x)
            xMax = maxFloat(xMax, point.x)
            yMin = minFloat(yMin, point.y)
            yMax = maxFloat(yMax, point.y)
        }
        var xSpan = xMax - xMin
        if (xSpan <= 0.0) {
            xSpan = 1.0
        }
        var ySpan = yMax - yMin
        if (ySpan <= 0.0) {
            ySpan = 1.0
        }
        let axisMinX = match (config.xAxis.min) {
            case Some(value) => value
            case None => xMin - xSpan * 0.05
        }
        let axisMaxX = match (config.xAxis.max) {
            case Some(value) => value
            case None => xMax + xSpan * 0.05
        }
        let axisMinY = match (config.yAxis.min) {
            case Some(value) => value
            case None => yMin - ySpan * 0.08
        }
        let axisMaxY = match (config.yAxis.max) {
            case Some(value) => value
            case None => yMax + ySpan * 0.08
        }
        if (axisMaxX <= axisMinX) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        if (axisMaxY <= axisMinY) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(axisMinX, axisMaxX, config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(axisMinY, axisMaxY, config.yAxis.tickCount)
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
        let xScale = LinearScale(axisMinX, axisMaxX, frame.plot.x, frame.plot.right())
        let yScale = LinearScale(axisMinY, axisMaxY, frame.plot.bottom(), frame.plot.y)

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

        for (threshold in [-foldChangeThreshold, foldChangeThreshold]) {
            let x = xScale.scale(threshold)
            kit.line(
                x, frame.plot.y, x, frame.plot.bottom(),
                stroke: "#bdbdbd", strokeWidth: 1.0,
                className: "volcano-threshold", dash: "5 4"
            )
        }
        let thresholdY = yScale.scale(pThreshold)
        kit.line(
            frame.plot.x, thresholdY, frame.plot.right(), thresholdY,
            stroke: "#bdbdbd", strokeWidth: 1.0,
            className: "volcano-threshold", dash: "5 4"
        )

        for (point in pointArray) {
            let category = volcanoCategory(point.x, point.y, foldChangeThreshold, pThreshold)
            let color = if (category == "up") {
                upColor
            } else if (category == "down") {
                downColor
            } else {
                neutralColor
            }
            let className = if (category == "up") {
                "volcano-point volcano-up"
            } else if (category == "down") {
                "volcano-point volcano-down"
            } else {
                "volcano-point volcano-nonsig"
            }
            let cx = xScale.scale(point.x)
            let cy = yScale.scale(point.y)
            kit.circle(cx, cy, 4.0, fill: color, className: className)
            if (category != "none" && !point.label.isEmpty()) {
                let text = volcanoLabelText(point.label, 10)
                kit.text(
                    cx + 6.0, cy + config.theme.fontSize / 3.0, text,
                    size: config.theme.fontSize - 1.0,
                    color: color,
                    className: "volcano-label"
                )
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}

/** 读取允许为负的数字字段。 */
internal func volcanoNumber(json: ChartJson, field: String, itemPath: String): Float64 {
    let value = json.required(field)
    if (!(value.kind.isInt || value.kind.isDecimal)) {
        throw chartInvalidValue("${itemPath}.${field}", "期望数字")
    }
    jsonNumberValue(value, "${itemPath}.${field}")
}

/** 按字符数截断标签，超出部分以省略号结尾。 */
internal func volcanoLabelText(text: String, limit: Int64): String {
    var count: Int64 = 0
    var result = ""
    for (rune in text.runes()) {
        if (count >= limit) {
            return result + "…"
        }
        result += rune.toString()
        count++
    }
    text
}

/** 依据阈值返回 `up` / `down` / `none`。 */
internal func volcanoCategory(
    x: Float64,
    y: Float64,
    foldChangeThreshold: Float64,
    pThreshold: Float64
): String {
    if (y < pThreshold) {
        return "none"
    }
    if (x >= foldChangeThreshold) {
        return "up"
    }
    if (x <= -foldChangeThreshold) {
        return "down"
    }
    "none"
}
