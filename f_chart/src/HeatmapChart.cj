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

/** M43 热力图：二维矩阵按数值映射为颜色。 */
public class HeatmapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "heatmap")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "热力图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "矩阵不能为空")
        }
        let matrix = ArrayList<Array<Float64>>()
        var minValue = 0.0
        var maxValue = 0.0
        var hasValue = false
        var rowIndex = 0
        for (rowValue in items) {
            let rowPath = "series[0].data[${rowIndex}]"
            if (!rowValue.kind.isArray) {
                throw chartInvalidValue(rowPath, "期望数组行")
            }
            let rowItems = rowValue.asArray().getItems()
            if (rowItems.isEmpty()) {
                throw chartInvalidValue(rowPath, "行不能为空")
            }
            if (rowIndex > 0 && rowItems.size != matrix[0].size) {
                throw chartInvalidValue(
                    rowPath,
                    "行长度 ${rowItems.size} 与首行 ${matrix[0].size} 不一致"
                )
            }
            let row = ArrayList<Float64>()
            var columnIndex = 0
            for (cell in rowItems) {
                let cellPath = "${rowPath}[${columnIndex}]"
                if (!(cell.kind.isInt || cell.kind.isDecimal)) {
                    throw chartInvalidValue(cellPath, "期望数字")
                }
                let value = jsonNumberValue(cell, cellPath)
                if (!hasValue) {
                    minValue = value
                    maxValue = value
                    hasValue = true
                } else {
                    minValue = minFloat(minValue, value)
                    maxValue = maxFloat(maxValue, value)
                }
                row.add(value)
                columnIndex++
            }
            matrix.add(row.toArray())
            rowIndex++
        }
        if (!hasValue) {
            throw chartInvalidValue("series[0].data", "矩阵不能为空")
        }
        let rowCount = matrix.size
        let columnCount = matrix[0].size
        let xLabels = resolveLabels(config.xAxis.labels, columnCount, "xAxis.labels")
        let yLabels = resolveLabels(config.yAxis.labels, rowCount, "yAxis.labels")
        let colorRange = root.stringArray(
            "colorRange",
            default: ["#f7fbff", "#6baed6", "#08306b"]
        )
        if (colorRange.size != 3) {
            throw chartInvalidValue("colorRange", "期望 [低, 中, 高] 三个颜色")
        }
        let colorLow = colorRange[0]
        let colorMid = colorRange[1]
        let colorHigh = colorRange[2]
        let showValues = root.bool("showValues", default: false)
        let cellGap = root.number("cellGap", default: 1.0)
        if (cellGap < 0.0) {
            throw chartInvalidValue("cellGap", "单元格间隙不能为负")
        }

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
        var maxYLabelWidth = 0.0
        for (label in yLabels) {
            let width = chartTextWidth(label, config.theme.fontSize)
            if (width > maxYLabelWidth) {
                maxYLabelWidth = width
            }
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight
        )
        let columnBand = BandScale(frame.plot.x, frame.plot.right(), columnCount)
        let cellWidth = frame.plot.width / Float64(columnCount)
        let cellHeight = frame.plot.height / Float64(rowCount)

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
        let legendColors: Array<String> = if (legendVisible) { [colorMid] } else { Array<String>() }
        frame.drawLegend(kit, legendNames, legendColors)

        let span = maxValue - minValue
        for (rowIndex in 0..rowCount) {
            for (columnIndex in 0..columnCount) {
                let value = matrix[rowIndex][columnIndex]
                let ratio = if (span <= 0.0) {
                    0.5
                } else {
                    (value - minValue) / span
                }
                let color = heatmapColor(ratio, colorLow, colorMid, colorHigh)
                let x = frame.plot.x + Float64(columnIndex) * cellWidth + cellGap / 2.0
                let y = frame.plot.y + Float64(rowIndex) * cellHeight + cellGap / 2.0
                kit.rect(
                    x, y, cellWidth - cellGap, cellHeight - cellGap,
                    fill: color, className: "heatmap-cell"
                )
                if (showValues) {
                    kit.text(
                        x + (cellWidth - cellGap) / 2.0,
                        y + (cellHeight - cellGap) / 2.0,
                        chartFormatTick(value, "{value}"),
                        size: config.theme.fontSize,
                        color: if (ratio > 0.6) { "#ffffff" } else { config.theme.textColor },
                        anchor: "middle",
                        className: "heatmap-value"
                    )
                }
            }
        }

        kit.line(
            frame.plot.x, frame.plot.y, frame.plot.x, frame.plot.bottom(),
            stroke: config.theme.axisColor, strokeWidth: 1.0, className: "axis"
        )
        for (rowIndex in 0..rowCount) {
            kit.text(
                frame.plot.x - 8.0,
                frame.plot.y + (Float64(rowIndex) + 0.5) * cellHeight,
                yLabels[rowIndex],
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "tick-label"
            )
        }
        if (!config.yAxis.title.isEmpty()) {
            kit.text(
                14.0, frame.plot.centerY(), config.yAxis.title,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "axis-title",
                rotate: -90.0
            )
        }
        frame.drawXAxis(kit, xLabels, columnBand)
        builder.toSvgString()
    }

    private func resolveLabels(labels: Array<String>, count: Int64, path: String): Array<String> {
        if (!labels.isEmpty()) {
            if (labels.size != count) {
                throw chartInvalidValue(
                    path,
                    "标签长度 ${labels.size} 与矩阵维度 ${count} 不一致"
                )
            }
            return labels
        }
        let generated = ArrayList<String>()
        for (index in 0..count) {
            generated.add((index + 1).toString())
        }
        generated.toArray()
    }
}

/** 归一化比例 → 三色线性插值。 */
internal func heatmapColor(ratio: Float64, low: String, mid: String, high: String): String {
    var value = ratio
    if (value < 0.0) {
        value = 0.0
    }
    if (value > 1.0) {
        value = 1.0
    }
    let lowColor = parseHeatmapColor(low, "colorRange[0]")
    let midColor = parseHeatmapColor(mid, "colorRange[1]")
    let highColor = parseHeatmapColor(high, "colorRange[2]")
    var start = lowColor
    var end = midColor
    var fraction = value * 2.0
    if (value > 0.5) {
        start = midColor
        end = highColor
        fraction = (value - 0.5) * 2.0
    }
    let red = mixHeatmapChannel(start.red, end.red, fraction)
    let green = mixHeatmapChannel(start.green, end.green, fraction)
    let blue = mixHeatmapChannel(start.blue, end.blue, fraction)
    SvgColor.fromRgb(red, green, blue).toString()
}

private func parseHeatmapColor(text: String, path: String): SvgColor {
    match (SvgColor.tryParse(text)) {
        case Some(color) => color
        case None => throw chartInvalidValue(path, "非法颜色 ${text}")
    }
}

private func mixHeatmapChannel(from: UInt8, to: UInt8, fraction: Float64): UInt8 {
    let start = Float64(Int64(from))
    let end = Float64(Int64(to))
    UInt8(Int64(round(start + (end - start) * fraction)))
}
