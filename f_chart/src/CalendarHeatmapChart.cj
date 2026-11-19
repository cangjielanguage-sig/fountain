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
import fountain::f_svg.{SvgBuilder, SvgViewBox, SvgColor}

/** M44 日历热力图：按天排成周 × 星期网格。 */
public class CalendarHeatmapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "calendar-heatmap")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "日历热力图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()

        let dayList = ArrayList<Int64>()
        let valueList = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {date, value} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let dateText = json.requiredString("date")
            let days = ChartTime.parseDays(dateText, "${itemPath}.date")
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            if (value < 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值不能为负")
            }
            dayList.add(Int64(days))
            valueList.add(value)
            index++
        }

        let startText = root.string("startDate")
        let endText = root.string("endDate")
        if (dayList.isEmpty() && (startText.isNone() || endText.isNone())) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        var startDays = 0
        var endDays = 0
        match (startText) {
            case Some(text) => startDays = Int64(ChartTime.parseDays(text, "startDate"))
            case None =>
                var minimum = dayList[0]
                for (day in dayList) {
                    minimum = if (day < minimum) { day } else { minimum }
                }
                startDays = minimum
        }
        match (endText) {
            case Some(text) => endDays = Int64(ChartTime.parseDays(text, "endDate"))
            case None =>
                var maximum = dayList[0]
                for (day in dayList) {
                    maximum = if (day > maximum) { day } else { maximum }
                }
                endDays = maximum
        }
        if (endDays < startDays) {
            throw chartInvalidValue("endDate", "endDate 必须不早于 startDate")
        }
        for (day in dayList) {
            if (day < startDays || day > endDays) {
                throw chartInvalidValue(
                    "series[0].data",
                    "日期 ${ChartTime.formatDays(Float64(day))} 超出 startDate/endDate 范围"
                )
            }
        }

        let weekStart = root.string("weekStart", default: "mon")
        if (weekStart != "mon" && weekStart != "sun") {
            throw chartInvalidValue("weekStart", "期望 mon / sun")
        }
        let cellSize = root.number("cellSize", default: 14.0)
        if (cellSize <= 0.0) {
            throw chartInvalidValue("cellSize", "单元格尺寸必须大于 0")
        }
        let colorRange = root.stringArray(
            "colorRange",
            default: ["#ebedf0", "#9be9a8", "#40c463", "#216e39"]
        )
        if (colorRange.size < 2) {
            throw chartInvalidValue("colorRange", "至少需要两个颜色")
        }
        for (colorIndex in 0..colorRange.size) {
            match (SvgColor.tryParse(colorRange[colorIndex])) {
                case Some(_) => ()
                case None =>
                    throw chartInvalidValue(
                        "colorRange[${colorIndex}]",
                        "非法颜色 ${colorRange[colorIndex]}"
                    )
            }
        }

        let uniqueDays = ArrayList<Int64>()
        let totals = ArrayList<Float64>()
        for (position in 0..dayList.size) {
            let day = dayList[position]
            var found = -1
            for (existing in 0..uniqueDays.size) {
                if (uniqueDays[existing] == day) {
                    found = existing
                    break
                }
            }
            if (found >= 0) {
                totals[found] = totals[found] + valueList[position]
            } else {
                uniqueDays.add(day)
                totals.add(valueList[position])
            }
        }
        var maxValue = 0.0
        for (total in totals) {
            maxValue = maxFloat(maxValue, total)
        }

        let startWeekday = calendarWeekday(Float64(startDays), weekStart)
        let dayCount = endDays - startDays + 1
        let weekCount = (dayCount + startWeekday + 6) / 7

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
        let frame = ChartFrame(config, legendVisible, 26.0, 18.0)
        var cell = minFloat(cellSize, frame.plot.width / Float64(weekCount))
        cell = minFloat(cell, frame.plot.height / 7.0)
        if (cell < 1.0) {
            cell = 1.0
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
        let legendColors: Array<String> = if (legendVisible) {
            [colorRange[colorRange.size - 1]]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)

        var lastMonth = -1
        for (offset in 0..dayCount) {
            let day = startDays + offset
            let slot = offset + startWeekday
            let week = slot / 7
            let row = slot % 7
            let x = frame.plot.x + Float64(week) * cell
            let y = frame.plot.y + Float64(row) * cell
            var total = 0.0
            for (position in 0..uniqueDays.size) {
                if (uniqueDays[position] == day) {
                    total = totals[position]
                    break
                }
            }
            let ratio = if (maxValue <= 0.0) { 0.0 } else { total / maxValue }
            let inset = if (cell > 2.0) { 1.0 } else { 0.0 }
            kit.rect(
                x + inset / 2.0, y + inset / 2.0,
                cell - inset, cell - inset,
                fill: calendarColor(ratio, colorRange), className: "calendar-cell"
            )
            let parts = ChartTime.partsOfDays(Float64(day))
            if (parts[1] != lastMonth) {
                lastMonth = parts[1]
                kit.text(
                    x + cell / 2.0, frame.plot.y - 6.0,
                    "${parts[1]}月",
                    size: config.theme.fontSize - 1.0,
                    color: config.theme.axisColor,
                    anchor: "middle",
                    className: "month-label"
                )
            }
        }

        let weekdayNames = if (weekStart == "mon") {
            ["一", "三", "五", "日"]
        } else {
            ["日", "二", "四", "六"]
        }
        for (position in 0..4) {
            kit.text(
                frame.plot.x - 4.0,
                frame.plot.y + (Float64(position * 2) + 0.5) * cell,
                weekdayNames[position],
                size: config.theme.fontSize - 1.0,
                color: config.theme.axisColor,
                anchor: "end",
                className: "weekday-label"
            )
        }
        builder.toSvgString()
    }
}

/** 星期下标：`mon` 时周一为 0，`sun` 时周日为 0。 */
internal func calendarWeekday(days: Float64, weekStart: String): Int64 {
    let raw = Int64(floor(days))
    var mondayIndex = (raw + 3) % 7
    if (mondayIndex < 0) {
        mondayIndex += 7
    }
    if (weekStart == "sun") {
        (mondayIndex + 1) % 7
    } else {
        mondayIndex
    }
}

/** 归一化比例 → 颜色分档；比例 1 取最后一档。 */
internal func calendarColor(ratio: Float64, colors: Array<String>): String {
    if (colors.isEmpty()) {
        return "#ebedf0"
    }
    var value = ratio
    if (value < 0.0) {
        value = 0.0
    }
    if (value > 1.0) {
        value = 1.0
    }
    var index = Int64(floor(value * Float64(colors.size)))
    if (index >= colors.size) {
        index = colors.size - 1
    }
    colors[index]
}
