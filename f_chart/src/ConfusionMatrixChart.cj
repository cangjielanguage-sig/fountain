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

/** M93b 混淆矩阵。 */
public class ConfusionMatrixChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "confusion-matrix")
        let root = ChartJson.of(data)
        let normalize = root.string("normalize", default: "none")
        if (normalize != "none" && normalize != "row" && normalize != "column") {
            throw chartInvalidValue("normalize", "仅支持 none / row / column")
        }
        let showValues = root.bool("showValues", default: true)
        let labels = root.stringArray("labels", default: Array<String>())
        if (labels.isEmpty()) {
            throw chartMissingField("labels")
        }

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "混淆矩阵仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let rowItems = dataArray.getItems()
        if (rowItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "矩阵不能为空")
        }
        if (rowItems.size != labels.size) {
            throw chartInvalidValue("labels", "标签数量与矩阵行数不一致")
        }
        let matrix = ArrayList<Array<Float64>>()
        var rowIndex = 0
        for (rowItem in rowItems) {
            let rowPath = "series[0].data[${rowIndex}]"
            if (!rowItem.kind.isArray) {
                throw chartInvalidValue(rowPath, "期望数组")
            }
            let cells = rowItem.asArray().getItems()
            if (cells.size != labels.size) {
                throw chartInvalidValue(rowPath, "矩阵必须为 N×N 方阵")
            }
            let row = ArrayList<Float64>()
            var columnIndex = 0
            for (cell in cells) {
                if (!(cell.kind.isInt || cell.kind.isDecimal)) {
                    throw chartInvalidValue(
                        "${rowPath}[${columnIndex}]", "期望数字"
                    )
                }
                let value = jsonNumberValue(cell, "${rowPath}[${columnIndex}]")
                if (value < 0.0) {
                    throw chartInvalidValue("${rowPath}[${columnIndex}]", "计数不能为负")
                }
                row.add(value)
                columnIndex++
            }
            matrix.add(row.toArray())
            rowIndex++
        }
        let rawMatrix = matrix.toArray()
        let displayMatrix = confusionNormalize(rawMatrix, normalize)

        var maxValue = 0.0
        for (row in displayMatrix) {
            for (value in row) {
                maxValue = maxFloat(maxValue, value)
            }
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let plot = frame.plot
        var maxLabelWidth = 0.0
        for (label in labels) {
            maxLabelWidth = maxFloat(maxLabelWidth, chartTextWidth(label, config.theme.fontSize))
        }
        let rowLabelWidth = maxLabelWidth + 12.0
        let columnLabelHeight = config.theme.fontSize + 12.0
        let gridWidth = plot.width - rowLabelWidth
        let gridHeight = plot.height - columnLabelHeight
        let count = labels.size
        let cellSize = maxFloat(
            minFloat(gridWidth / Float64(count), gridHeight / Float64(count)), 1.0
        )
        let totalSize = cellSize * Float64(count)
        let gridX = plot.x + rowLabelWidth + (gridWidth - totalSize) / 2.0
        let gridY = plot.y + columnLabelHeight + (gridHeight - totalSize) / 2.0

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        let palette = ["#e3f2fd", "#0d47a1"]
        for (row in 0..count) {
            for (column in 0..count) {
                let value = displayMatrix[row][column]
                let ratio = if (maxValue <= 0.0) { 0.0 } else { value / maxValue }
                let color = heatFlameColor(ratio, palette)
                let x = gridX + Float64(column) * cellSize
                let y = gridY + Float64(row) * cellSize
                kit.rect(
                    x, y, cellSize, cellSize,
                    fill: color,
                    stroke: "#ffffff",
                    strokeWidth: 1.0,
                    className: "confusion-cell"
                )
                if (showValues) {
                    kit.text(
                        x + cellSize / 2.0,
                        y + cellSize / 2.0 + config.theme.fontSize / 3.0,
                        confusionText(value, normalize != "none"),
                        size: config.theme.fontSize,
                        color: if (ratio > 0.6) { "#ffffff" } else { "#212121" },
                        anchor: "middle",
                        className: "confusion-value"
                    )
                }
            }
        }

        for (row in 0..count) {
            kit.text(
                gridX - 8.0,
                gridY + Float64(row) * cellSize + cellSize / 2.0 + config.theme.fontSize / 3.0,
                labels[row],
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "confusion-label"
            )
        }
        for (column in 0..count) {
            kit.text(
                gridX + Float64(column) * cellSize + cellSize / 2.0,
                gridY - 6.0,
                labels[column],
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "confusion-label"
            )
        }
        builder.toSvgString()
    }
}

/** 按模式归一化矩阵：`row` 行和为 1、`column` 列和为 1。 */
internal func confusionNormalize(
    matrix: Array<Array<Float64>>,
    mode: String
): Array<Array<Float64>> {
    let rows = matrix.size
    if (rows == 0) {
        return matrix
    }
    let columns = matrix[0].size
    let result = ArrayList<Array<Float64>>()
    for (row in 0..rows) {
        let values = ArrayList<Float64>()
        for (column in 0..columns) {
            values.add(matrix[row][column])
        }
        result.add(values.toArray())
    }
    if (mode == "row") {
        for (row in 0..rows) {
            var total = 0.0
            for (column in 0..columns) {
                total += result[row][column]
            }
            if (total > 0.0) {
                for (column in 0..columns) {
                    result[row][column] = result[row][column] / total
                }
            }
        }
    } else if (mode == "column") {
        for (column in 0..columns) {
            var total = 0.0
            for (row in 0..rows) {
                total += result[row][column]
            }
            if (total > 0.0) {
                for (row in 0..rows) {
                    result[row][column] = result[row][column] / total
                }
            }
        }
    }
    result.toArray()
}

/** 单元格文本：原始计数取整，归一化值保留两位小数。 */
internal func confusionText(value: Float64, normalized: Bool): String {
    if (!normalized) {
        return formatSvgNumber(value)
    }
    let hundredths = Int64(round(value * 100.0))
    let whole = hundredths / 100
    let fraction = hundredths % 100
    let padded = if (fraction < 10) { "0${fraction}" } else { "${fraction}" }
    "${whole}.${padded}"
}
