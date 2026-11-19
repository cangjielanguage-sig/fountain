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

/** 象形图的一个数据项。 */
internal class PictogramItem {
    let name: String
    let value: Float64
    let seriesIndex: Int64

    init(name: String, value: Float64, seriesIndex: Int64) {
        this.name = name
        this.value = value
        this.seriesIndex = seriesIndex
    }
}

/** M74 象形图。 */
public class PictogramChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "pictogram")
        let root = ChartJson.of(data)
        let icon = root.string("icon", default: "circle")
        if (icon.isEmpty()) {
            throw chartInvalidValue("icon", "图标不能为空")
        }
        let unit = root.number("unit", default: 1.0)
        if (unit <= 0.0) {
            throw chartInvalidValue("unit", "单位必须大于 0")
        }
        let columnsValue = root.number("columns", default: 10.0)
        if (columnsValue < 1.0 || columnsValue != floor(columnsValue)) {
            throw chartInvalidValue("columns", "列数必须为正整数")
        }
        let columns = Int64(columnsValue)

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartInvalidValue("series", "至少需要一个系列")
        }
        let items = ArrayList<PictogramItem>()
        var seriesIndex = 0
        for (seriesItem in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!seriesItem.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let seriesJson = ChartJson.of(seriesItem.asObject(), seriesPath)
            let dataArray = seriesJson.requiredArray("data")
            let dataItems = dataArray.getItems()
            if (dataItems.isEmpty()) {
                throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
            }
            var itemIndex = 0
            for (item in dataItems) {
                let itemPath = "${seriesPath}.data[${itemIndex}]"
                if (!item.kind.isObject) {
                    throw chartInvalidValue(itemPath, "期望 {name,value} 对象")
                }
                let json = ChartJson.of(item.asObject(), itemPath)
                let name = json.string("name", default: (itemIndex + 1).toString())
                let valueJson = json.required("value")
                if (!(valueJson.kind.isInt || valueJson.kind.isDecimal)) {
                    throw chartInvalidValue("${itemPath}.value", "期望数字")
                }
                let value = jsonNumberValue(valueJson, "${itemPath}.value")
                if (value < 0.0) {
                    throw chartInvalidValue("${itemPath}.value", "数值不能为负")
                }
                items.add(PictogramItem(name, value, seriesIndex))
                itemIndex++
            }
            seriesIndex++
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let plot = frame.plot
        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        let iconSize = 22.0
        let iconGap = 4.0
        var cursorY = plot.y + 6.0
        for (item in items) {
            let color = config.theme.colorAt(item.seriesIndex)
            kit.text(
                plot.x,
                cursorY + config.theme.fontSize,
                "${item.name} ${formatSvgNumber(item.value)}",
                size: config.theme.fontSize,
                color: config.theme.textColor,
                className: "pictogram-label"
            )
            cursorY += 20.0
            let iconCount = pictogramCount(item.value, unit)
            var drawn: Int64 = 0
            while (drawn < iconCount) {
                let row = drawn / columns
                let column = drawn % columns
                let iconX = plot.x + Float64(column) * (iconSize + iconGap)
                let iconY = cursorY + Float64(row) * (iconSize + iconGap)
                kit.path(
                    pictogramIconPath(icon, iconX, iconY, iconSize),
                    fill: color,
                    className: "pictogram-icon"
                )
                drawn++
            }
            let rows = (iconCount + columns - 1) / columns
            cursorY += Float64(rows) * (iconSize + iconGap) + 12.0
        }
        builder.toSvgString()
    }
}

/** 每个图标代表的数值向上取整。 */
internal func pictogramCount(value: Float64, unit: Float64): Int64 {
    if (value <= 0.0 || unit <= 0.0) {
        return 0
    }
    Int64(ceil(value / unit))
}

/** 生成图标路径；内置形状按 `x`/`y`/`size` 定位，其余字符串原样返回。 */
internal func pictogramIconPath(icon: String, x: Float64, y: Float64, size: Float64): String {
    match (icon) {
        case "circle" =>
            let centerX = x + size / 2.0
            let centerY = y + size / 2.0
            let radius = size / 2.0
            "M ${formatSvgNumber(centerX - radius)} ${formatSvgNumber(centerY)}" +
                " A ${formatSvgNumber(radius)} ${formatSvgNumber(radius)} 0 1 0 " +
                "${formatSvgNumber(centerX + radius)} ${formatSvgNumber(centerY)}" +
                " A ${formatSvgNumber(radius)} ${formatSvgNumber(radius)} 0 1 0 " +
                "${formatSvgNumber(centerX - radius)} ${formatSvgNumber(centerY)} Z"
        case "square" =>
            "M ${formatSvgNumber(x)} ${formatSvgNumber(y)}" +
                " H ${formatSvgNumber(x + size)} V ${formatSvgNumber(y + size)}" +
                " H ${formatSvgNumber(x)} Z"
        case "person" =>
            let headX = x + size * 0.5
            let headTop = y + size * 0.06
            let headBottom = y + size * 0.48
            let headRadius = size * 0.2
            let shoulderLeft = x + size * 0.12
            let shoulderRight = x + size * 0.88
            let bodyBottom = y + size
            let bodyTop = y + size * 0.52
            "M ${formatSvgNumber(headX)} ${formatSvgNumber(headTop)}" +
                " A ${formatSvgNumber(headRadius)} ${formatSvgNumber(headRadius)} 0 1 0 " +
                "${formatSvgNumber(headX)} ${formatSvgNumber(headBottom)}" +
                " A ${formatSvgNumber(headRadius)} ${formatSvgNumber(headRadius)} 0 1 0 " +
                "${formatSvgNumber(headX)} ${formatSvgNumber(headTop)} Z" +
                " M ${formatSvgNumber(shoulderLeft)} ${formatSvgNumber(bodyBottom)}" +
                " C ${formatSvgNumber(shoulderLeft)} ${formatSvgNumber(y + size * 0.64)}" +
                " ${formatSvgNumber(x + size * 0.3)} ${formatSvgNumber(bodyTop)}" +
                " ${formatSvgNumber(headX)} ${formatSvgNumber(bodyTop)}" +
                " C ${formatSvgNumber(x + size * 0.7)} ${formatSvgNumber(bodyTop)}" +
                " ${formatSvgNumber(shoulderRight)} ${formatSvgNumber(y + size * 0.64)}" +
                " ${formatSvgNumber(shoulderRight)} ${formatSvgNumber(bodyBottom)} Z"
        case _ => icon
    }
}
