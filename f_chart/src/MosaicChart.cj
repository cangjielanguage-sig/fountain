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

/** 马赛克图的一个系列（第二维类别）。 */
internal class MosaicSeries {
    let name: String
    let values: Array<Float64>

    init(name: String, values: Array<Float64>) {
        this.name = name
        this.values = values
    }
}

/**
 * M33 马赛克图。
 *
 * 列宽编码第一维总量，列内高度编码第二维构成。
 */
public class MosaicChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "mosaic")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<MosaicSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: (seriesIndex + 1).toString())
            let dataArray = json.requiredArray("data")
            let values = ArrayList<Float64>()
            var valueIndex = 0
            for (entry in dataArray.getItems()) {
                let valuePath = "${path}.data[${valueIndex}]"
                if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                    throw chartInvalidValue(valuePath, "期望数字")
                }
                let value = jsonNumberValue(entry, valuePath)
                if (value < 0.0) {
                    throw chartInvalidValue(valuePath, "计数不能为负")
                }
                values.add(value)
                valueIndex++
            }
            series.add(MosaicSeries(name, values.toArray()))
            seriesIndex++
        }
        var categoryCount = config.xAxis.labels.size
        if (categoryCount == 0) {
            for (item in series) {
                categoryCount = maxInt64(categoryCount, item.values.size)
            }
        }
        for (index in 0..series.size) {
            if (series[index].values.size != categoryCount) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${series[index].values.size} 与类别数 ${categoryCount} 不一致"
                )
            }
        }
        let valuesMatrix = ArrayList<Array<Float64>>()
        for (item in series) {
            valuesMatrix.add(item.values)
        }
        let totals = mosaicColumnTotals(valuesMatrix.toArray(), categoryCount)
        var grandTotal = 0.0
        for (total in totals) {
            grandTotal += total
        }
        if (grandTotal <= 0.0) {
            throw chartInvalidValue("series", "列总和必须大于 0")
        }

        let labels = ArrayList<String>()
        for (index in 0..categoryCount) {
            labels.add(if (index < config.xAxis.labels.size) {
                config.xAxis.labels[index]
            } else {
                (index + 1).toString()
            })
        }

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

        let left = config.padding.left + 20.0
        let right = config.width - config.padding.right - 20.0
        let top = config.padding.top + 64.0
        let bottom = config.height - config.padding.bottom - 40.0
        let plotHeight = bottom - top
        let plotWidth = right - left

        var legendX = left
        for (index in 0..series.size) {
            let color = config.theme.colorAt(index)
            kit.rect(
                legendX, config.padding.top + 38.0, 10.0, 10.0,
                fill: color, className: "legend-item"
            )
            kit.text(
                legendX + 14.0, config.padding.top + 47.0, series[index].name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                className: "legend-label"
            )
            legendX += 14.0 + chartTextWidth(series[index].name, config.theme.fontSize) + 18.0
        }

        var cursorX = left
        for (column in 0..categoryCount) {
            let columnWidth = totals[column] / grandTotal * plotWidth
            var cursorY = bottom
            for (index in 0..series.size) {
                let share = if (totals[column] > 0.0) {
                    series[index].values[column] / totals[column]
                } else {
                    0.0
                }
                let cellHeight = share * plotHeight
                kit.rect(
                    cursorX, cursorY - cellHeight, columnWidth, cellHeight,
                    fill: config.theme.colorAt(index), stroke: "#ffffff", strokeWidth: 1.0,
                    className: "mosaic-cell"
                )
                cursorY -= cellHeight
            }
            kit.text(
                cursorX + columnWidth / 2.0, bottom + 18.0, labels[column],
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "mosaic-label"
            )
            cursorX += columnWidth
        }
        builder.toSvgString()
    }
}

/** 各列总和。 */
internal func mosaicColumnTotals(
    values: Array<Array<Float64>>,
    count: Int64
): Array<Float64> {
    let totals = ArrayList<Float64>()
    for (_ in 0..count) {
        totals.add(0.0)
    }
    for (row in values) {
        for (index in 0..count) {
            if (index < row.size) {
                totals[index] = totals[index] + row[index]
            }
        }
    }
    totals.toArray()
}
