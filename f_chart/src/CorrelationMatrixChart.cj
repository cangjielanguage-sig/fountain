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
 * M27 相关矩阵图。
 *
 * 用颜色方阵展示变量间相关系数，可选显示数值。
 */
public class CorrelationMatrixChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "correlation-matrix")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "相关矩阵仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let rows = dataArray.getItems()
        if (rows.isEmpty()) {
            throw chartInvalidValue("series[0].data", "矩阵不能为空")
        }
        let matrix = ArrayList<Array<Float64>>()
        var rowIndex = 0
        for (row in rows) {
            let rowPath = "series[0].data[${rowIndex}]"
            if (!row.kind.isArray) {
                throw chartInvalidValue(rowPath, "期望数值数组")
            }
            let values = ArrayList<Float64>()
            var columnIndex = 0
            for (entry in row.asArray().getItems()) {
                let cellPath = "${rowPath}[${columnIndex}]"
                if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                    throw chartInvalidValue(cellPath, "期望数字")
                }
                let value = jsonNumberValue(entry, cellPath)
                if (value < -1.000001 || value > 1.000001) {
                    throw chartInvalidValue(cellPath, "相关系数必须在 -1 到 1 之间")
                }
                values.add(value)
                columnIndex++
            }
            matrix.add(values.toArray())
            rowIndex++
        }
        let order = matrix.size
        for (row in matrix) {
            if (row.size != order) {
                throw chartInvalidValue("series[0].data", "相关矩阵必须为方阵")
            }
        }
        let method = root.string("method", default: "pearson")
        if (method != "pearson" && method != "spearman") {
            throw chartInvalidValue("method", "期望 pearson / spearman")
        }
        let showValues = root.bool("showValues", default: true)
        let colors = resolveColorRange(root.value("colorRange"))

        let xLabels = resolveLabels(config.xAxis.labels, order, "xAxis.labels")
        let yLabels = resolveLabels(config.yAxis.labels, order, "yAxis.labels")

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

        let labelWidth = 64.0
        let topSpace = 58.0
        let bottomSpace = 44.0
        let availableWidth = config.width - config.padding.left - config.padding.right -
            labelWidth - 16.0
        let availableHeight = config.height - config.padding.top - config.padding.bottom -
            topSpace - bottomSpace
        let size = minFloat(availableWidth, availableHeight)
        let left = config.padding.left + labelWidth
        let top = config.padding.top + topSpace
        let cell = size / Float64(order)

        for (row in 0..order) {
            let labelY = top + (Float64(row) + 0.5) * cell + config.theme.fontSize / 3.0
            kit.text(
                left - 6.0, labelY, yLabels[row],
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "matrix-label"
            )
            for (column in 0..order) {
                let value = matrix[row][column]
                let x = left + Float64(column) * cell
                let y = top + Float64(row) * cell
                kit.rect(
                    x, y, cell, cell,
                    fill: correlationColor(value, colors[0], colors[1], colors[2]),
                    className: "correlation-cell"
                )
                if (showValues) {
                    kit.text(
                        x + cell / 2.0,
                        y + cell / 2.0 + config.theme.fontSize / 3.0,
                        formatCorrelation(value),
                        size: config.theme.fontSize,
                        color: if (abs(value) > 0.5) { "#ffffff" } else { "#333333" },
                        anchor: "middle",
                        className: "cell-value"
                    )
                }
            }
        }
        for (column in 0..order) {
            kit.text(
                left + (Float64(column) + 0.5) * cell,
                top + size + 18.0,
                xLabels[column],
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "matrix-label"
            )
        }
        builder.toSvgString()
    }

    private func resolveColorRange(value: ?JsonValue): Array<String> {
        let defaults = ["#d73027", "#ffffff", "#4575b4"]
        match (value) {
            case Some(item) =>
                if (!item.kind.isArray) {
                    throw chartInvalidValue("colorRange", "期望三色数组")
                }
                let items = item.asArray().getItems()
                if (items.size != 3) {
                    throw chartInvalidValue("colorRange", "期望三个颜色")
                }
                let colors = ArrayList<String>()
                var index = 0
                for (entry in items) {
                    if (!entry.kind.isString) {
                        throw chartInvalidValue("colorRange[${index}]", "期望颜色字符串")
                    }
                    colors.add(entry.asString().value)
                    index++
                }
                colors.toArray()
            case None => defaults
        }
    }

    private func resolveLabels(labels: Array<String>, count: Int64, path: String): Array<String> {
        if (!labels.isEmpty()) {
            if (labels.size != count) {
                throw chartInvalidValue(
                    path,
                    "标签长度 ${labels.size} 与矩阵阶数 ${count} 不一致"
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

/** 相关系数 → 三色分段。 */
internal func correlationColor(value: Float64, low: String, mid: String, high: String): String {
    if (value < -0.33) {
        low
    } else if (value <= 0.33) {
        mid
    } else {
        high
    }
}

/** 相关系数格式化：两位小数。 */
internal func formatCorrelation(value: Float64): String {
    let scaled = Int64(round(value * 100.0))
    let sign = if (scaled < 0) { "-" } else { "" }
    let magnitude = if (scaled < 0) { -scaled } else { scaled }
    let whole = magnitude / 100
    let fraction = magnitude % 100
    let fractionText = if (fraction < 10) {
        "0${fraction}"
    } else {
        fraction.toString()
    }
    "${sign}${whole}.${fractionText}"
}
