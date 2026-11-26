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

/** 螺旋图的一个周期数据。 */
internal class SpiralDatum {
    let period: String
    let value: Float64

    init(period: String, value: Float64) {
        this.period = period
        this.value = value
    }
}

/** M84 螺旋图。 */
public class SpiralChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "spiral")
        let root = ChartJson.of(data)
        let turns = root.number("turns", default: 3.0)
        if (turns <= 0.0) {
            throw chartInvalidValue("turns", "圈数必须大于 0")
        }
        let startAngle = root.number("startAngle", default: -90.0)
        let clockwise = root.bool("clockwise", default: true)

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "螺旋图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let values = ArrayList<SpiralDatum>()
        var maxValue = 0.0
        var index = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {period,value} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let period = json.requiredString("period")
            let valueJson = json.required("value")
            if (!(valueJson.kind.isInt || valueJson.kind.isDecimal)) {
                throw chartInvalidValue("${itemPath}.value", "期望数字")
            }
            let value = jsonNumberValue(valueJson, "${itemPath}.value")
            if (value < 0.0) {
                throw chartInvalidValue("${itemPath}.value", "数值不能为负")
            }
            maxValue = maxFloat(maxValue, value)
            values.add(SpiralDatum(period, value))
            index++
        }
        let dataValue = values.toArray()

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        if (!config.title.isEmpty()) {
            kit.text(
                config.width / 2.0, config.padding.top + config.titleFontSize,
                config.title,
                size: config.titleFontSize,
                color: config.titleColor,
                anchor: "middle",
                className: "title"
            )
        }

        let centerX = config.width / 2.0
        let centerY = config.height / 2.0 + 10.0
        let maxRadius = minFloat(
            config.width - config.padding.left - config.padding.right,
            config.height - config.padding.top - config.padding.bottom - 40.0
        ) / 2.0 - 30.0

        let count = dataValue.size
        let path = StringBuilder()
        for (index in 0..count) {
            let point = spiralPoint(
                index, count, turns, startAngle, clockwise, maxRadius
            )
            let x = centerX + point[0]
            let y = centerY + point[1]
            if (index == 0) {
                path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            } else {
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
            }
        }
        kit.path(
            path.toString(),
            fill: "none",
            stroke: "#b0bec5",
            strokeWidth: 1.5,
            className: "spiral-path"
        )

        for (index in 0..count) {
            let datum = dataValue[index]
            let point = spiralPoint(
                index, count, turns, startAngle, clockwise, maxRadius
            )
            let x = centerX + point[0]
            let y = centerY + point[1]
            let ratio = if (maxValue <= 0.0) { 0.0 } else { datum.value / maxValue }
            let radius = 3.0 + ratio * 5.0
            kit.circle(x, y, radius, fill: config.theme.colorAt(index), className: "spiral-point")
            let distance = sqrt(point[0] * point[0] + point[1] * point[1])
            let scale = if (distance <= 1e-9) { 1.0 } else { 1.0 + 12.0 / distance }
            kit.text(
                centerX + point[0] * scale,
                centerY + point[1] * scale + config.theme.fontSize / 3.0,
                datum.period,
                size: config.theme.fontSize - 1.0,
                color: config.theme.textColor,
                anchor: "middle",
                className: "spiral-label"
            )
        }
        builder.toSvgString()
    }
}

/** 第 `index` 个数据点相对圆心的坐标。 */
internal func spiralPoint(
    index: Int64,
    count: Int64,
    turns: Float64,
    startAngle: Float64,
    clockwise: Bool,
    maxRadius: Float64
): Array<Float64> {
    let direction = if (clockwise) { 1.0 } else { -1.0 }
    let divisor = if (count > 1) { Float64(count - 1) } else { 1.0 }
    let angle = startAngle + direction * turns * 360.0 * Float64(index) / divisor
    let radius = maxRadius * Float64(index + 1) / Float64(count)
    let radians = angle * 3.141592653589793 / 180.0
    [radius * cos(radians), radius * sin(radians)]
}
