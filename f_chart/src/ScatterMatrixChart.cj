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

/** 散点矩阵的一个系列。 */
internal class MatrixSeriesData {
    let name: String
    let color: ?String
    let rows: Array<Array<Float64>>

    init(name: String, color: ?String, rows: Array<Array<Float64>>) {
        this.name = name
        this.color = color
        this.rows = rows
    }
}

/**
 * M30 散点矩阵图。
 *
 * 变量两两组合成矩阵，对角显示变量名，非对角显示散点。
 */
public class ScatterMatrixChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "scatter-matrix")
        let root = ChartJson.of(data)
        let variablesArray = root.requiredArray("variables")
        let variableItems = variablesArray.getItems()
        if (variableItems.isEmpty()) {
            throw chartInvalidValue("variables", "变量不能为空")
        }
        let variables = ArrayList<String>()
        var variableIndex = 0
        for (item in variableItems) {
            if (!item.kind.isString) {
                throw chartInvalidValue("variables[${variableIndex}]", "期望变量名")
            }
            variables.add(item.asString().value)
            variableIndex++
        }
        let variableCount = variables.size

        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<MatrixSeriesData>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let color = json.string("color")
            let dataArray = json.requiredArray("data")
            let rows = ArrayList<Array<Float64>>()
            var rowIndex = 0
            for (row in dataArray.getItems()) {
                let rowPath = "${path}.data[${rowIndex}]"
                if (!row.kind.isArray) {
                    throw chartInvalidValue(rowPath, "期望数值数组")
                }
                let values = ArrayList<Float64>()
                var valueIndex = 0
                for (entry in row.asArray().getItems()) {
                    let valuePath = "${rowPath}[${valueIndex}]"
                    if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                        throw chartInvalidValue(valuePath, "期望数字")
                    }
                    values.add(jsonNumberValue(entry, valuePath))
                    valueIndex++
                }
                if (values.size != variableCount) {
                    throw chartInvalidValue(
                        rowPath,
                        "行长度 ${values.size} 与变量数 ${variableCount} 不一致"
                    )
                }
                rows.add(values.toArray())
                rowIndex++
            }
            series.add(MatrixSeriesData(name, color, rows.toArray()))
            seriesIndex++
        }

        let allRows = ArrayList<Array<Float64>>()
        for (item in series) {
            for (row in item.rows) {
                allRows.add(row)
            }
        }
        let ranges = ArrayList<Array<Float64>>()
        for (index in 0..variableCount) {
            ranges.add(columnRange(allRows.toArray(), index))
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

        let labelWidth = 70.0
        let topSpace = 44.0
        let bottomSpace = 32.0
        let availableWidth = config.width - config.padding.left - config.padding.right - labelWidth
        let availableHeight = config.height - config.padding.top - config.padding.bottom -
            topSpace - bottomSpace
        let size = minFloat(availableWidth, availableHeight)
        let left = config.padding.left + labelWidth
        let top = config.padding.top + topSpace
        let cell = size / Float64(variableCount)

        for (row in 0..variableCount) {
            for (column in 0..variableCount) {
                let x = left + Float64(column) * cell
                let y = top + Float64(row) * cell
                kit.rect(
                    x, y, cell, cell,
                    fill: "none", stroke: "#dddddd", strokeWidth: 1.0,
                    className: "matrix-cell"
                )
                if (row == column) {
                    kit.text(
                        x + cell / 2.0,
                        y + cell / 2.0 + config.theme.fontSize / 3.0,
                        variables[row],
                        size: config.theme.fontSize,
                        color: config.theme.textColor,
                        anchor: "middle",
                        className: "diag-label"
                    )
                }
            }
        }
        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            for (row in 0..variableCount) {
                for (column in 0..variableCount) {
                    if (row == column) {
                        continue
                    }
                    let cellX = left + Float64(column) * cell
                    let cellY = top + Float64(row) * cell
                    let xRange = ranges[column]
                    let yRange = ranges[row]
                    for (values in item.rows) {
                        let normalizedX = if (xRange[1] > xRange[0]) {
                            (values[column] - xRange[0]) / (xRange[1] - xRange[0])
                        } else {
                            0.5
                        }
                        let normalizedY = if (yRange[1] > yRange[0]) {
                            (values[row] - yRange[0]) / (yRange[1] - yRange[0])
                        } else {
                            0.5
                        }
                        kit.circle(
                            cellX + 6.0 + normalizedX * (cell - 12.0),
                            cellY + cell - 6.0 - normalizedY * (cell - 12.0),
                            2.0,
                            fill: color,
                            className: "matrix-point"
                        )
                    }
                }
            }
        }
        builder.toSvgString()
    }
}

/** 二维样本列的最小/最大值。 */
internal func columnRange(rows: Array<Array<Float64>>, index: Int64): Array<Float64> {
    if (rows.isEmpty()) {
        return [0.0, 1.0]
    }
    var minimum = rows[0][index]
    var maximum = rows[0][index]
    for (row in rows) {
        minimum = minFloat(minimum, row[index])
        maximum = maxFloat(maximum, row[index])
    }
    [minimum, maximum]
}
