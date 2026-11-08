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

/** 饼图的一个扇区。 */
internal class PieSlice {
    let name: String
    let value: Float64

    init(name: String, value: Float64) {
        this.name = name
        this.value = value
    }
}

/**
 * M31 饼图。
 *
 * 按数值占比绘制扇区，并可选显示百分比。
 */
public class PieChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "pie")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "饼图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let slices = ArrayList<PieSlice>()
        let values = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {name,value} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let name = json.string("name", default: (index + 1).toString())
            let valueJson = json.required("value")
            if (!(valueJson.kind.isInt || valueJson.kind.isDecimal)) {
                throw chartInvalidValue("${itemPath}.value", "期望数字")
            }
            let value = jsonNumberValue(valueJson, "${itemPath}.value")
            if (value < 0.0) {
                throw chartInvalidValue("${itemPath}.value", "份额不能为负")
            }
            slices.add(PieSlice(name, value))
            values.add(value)
            index++
        }
        let fractions = pieFractions(values.toArray())
        let startAngle = root.number("startAngle", default: 0.0)
        let showPercent = root.bool("showPercent", default: true)

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
        let radius = minFloat(
            config.width - config.padding.left - config.padding.right,
            config.height - config.padding.top - config.padding.bottom - 40.0
        ) / 2.0 - 20.0
        var angle = -90.0 + startAngle
        for (index in 0..slices.size) {
            let sweep = fractions[index] * 360.0
            let endAngle = angle + sweep
            if (sweep > 0.0) {
                let startX = centerX + radius * cos(angle * 3.141592653589793 / 180.0)
                let startY = centerY + radius * sin(angle * 3.141592653589793 / 180.0)
                let endX = centerX + radius * cos(endAngle * 3.141592653589793 / 180.0)
                let endY = centerY + radius * sin(endAngle * 3.141592653589793 / 180.0)
                let largeArc = if (sweep > 180.0) { 1 } else { 0 }
                let path = "M ${formatSvgNumber(centerX)} ${formatSvgNumber(centerY)}" +
                    " L ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                    " A ${formatSvgNumber(radius)} ${formatSvgNumber(radius)} 0 ${largeArc} 1 " +
                    "${formatSvgNumber(endX)} ${formatSvgNumber(endY)} Z"
                kit.path(
                    path, fill: config.theme.colorAt(index), stroke: "#ffffff", strokeWidth: 1.0,
                    className: "pie-slice"
                )
                let middle = angle + sweep / 2.0
                let labelX = centerX + radius * 0.65 * cos(middle * 3.141592653589793 / 180.0)
                let labelY = centerY + radius * 0.65 * sin(middle * 3.141592653589793 / 180.0) +
                    config.theme.fontSize / 3.0
                let text = if (showPercent) {
                    formatPercent(fractions[index])
                } else {
                    slices[index].name
                }
                kit.text(
                    labelX, labelY, text,
                    size: config.theme.fontSize,
                    color: "#333333",
                    anchor: "middle",
                    className: "pie-label"
                )
            }
            angle = endAngle
        }
        builder.toSvgString()
    }
}

/** 各值占总和的占比；总和必须大于 0。 */
internal func pieFractions(values: Array<Float64>): Array<Float64> {
    var total = 0.0
    for (value in values) {
        if (value < 0.0) {
            throw chartInvalidValue("series[0].data", "份额不能为负")
        }
        total += value
    }
    if (total <= 0.0) {
        throw chartInvalidValue("series[0].data", "份额总和必须大于 0")
    }
    let fractions = ArrayList<Float64>()
    for (value in values) {
        fractions.add(value / total)
    }
    fractions.toArray()
}

/** 占比 → 一位小数百分比。 */
internal func formatPercent(fraction: Float64): String {
    let tenths = Int64(round(fraction * 1000.0))
    let whole = tenths / 10
    let digit = tenths % 10
    "${whole}.${digit}%"
}
