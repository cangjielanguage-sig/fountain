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
 * M35 漏斗图。
 *
 * 从上到下绘制转化阶段梯形，并标注相邻阶段转化率。
 */
public class FunnelChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "funnel")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "漏斗图仅支持 1 个系列")
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
        let names = ArrayList<String>()
        let values = ArrayList<Float64>()
        var maxValue = 0.0
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
                throw chartInvalidValue("${itemPath}.value", "阶段值不能为负")
            }
            if (value > maxValue) {
                maxValue = value
            }
            names.add(name)
            values.add(value)
            index++
        }
        if (maxValue <= 0.0) {
            throw chartInvalidValue("series[0].data", "阶段最大值必须大于 0")
        }
        let gap = root.number("gap", default: 2.0)
        if (gap < 0.0) {
            throw chartInvalidValue("gap", "间距不能为负")
        }
        let showConversion = root.bool("showConversion", default: true)

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
        let top = config.padding.top + 60.0
        let bottom = config.height - config.padding.bottom - 30.0
        let maxWidth = config.width - config.padding.left - config.padding.right - 120.0
        let stageHeight = (bottom - top - gap * Float64(values.size - 1)) / Float64(values.size)
        for (position in 0..values.size) {
            let width = values[position] / maxValue * maxWidth
            let y0 = top + Float64(position) * (stageHeight + gap)
            kit.rect(
                centerX - width / 2.0, y0, width, stageHeight,
                fill: config.theme.colorAt(position), stroke: "#ffffff", strokeWidth: 1.0,
                className: "funnel-stage"
            )
            kit.text(
                centerX, y0 + stageHeight / 2.0 + config.theme.fontSize / 3.0,
                names[position] + " " + values[position].toString(),
                size: config.theme.fontSize,
                color: "#ffffff",
                anchor: "middle",
                className: "stage-label"
            )
            if (showConversion && position + 1 < values.size) {
                let conversion = funnelConversion(values[position], values[position + 1])
                let conversionText = formatPercent(conversion / 100.0)
                kit.text(
                    centerX, y0 + stageHeight + gap + config.theme.fontSize,
                    conversionText,
                    size: config.theme.fontSize - 1.0,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "conversion-label"
                )
            }
        }
        builder.toSvgString()
    }
}

/** 相邻阶段转化率（百分比）。 */
internal func funnelConversion(current: Float64, next: Float64): Float64 {
    if (current <= 0.0) {
        0.0
    } else {
        next / current * 100.0
    }
}
