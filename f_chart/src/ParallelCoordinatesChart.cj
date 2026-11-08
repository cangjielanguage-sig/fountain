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

/** 平行坐标的一个维度。 */
internal class ParallelDimension {
    let name: String
    let minimum: Float64
    let maximum: Float64

    init(name: String, minimum: Float64, maximum: Float64) {
        this.name = name
        this.minimum = minimum
        this.maximum = maximum
    }
}

/** 平行坐标的一组样本。 */
internal class ParallelSeriesData {
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
 * M28 平行坐标图。
 *
 * 每个样本在多个维度轴上形成一条折线，用于观察多维走势。
 */
public class ParallelCoordinatesChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "parallel-coordinates")
        let root = ChartJson.of(data)
        let dimensionArray = root.requiredArray("dimensions")
        let dimensionItems = dimensionArray.getItems()
        if (dimensionItems.isEmpty()) {
            throw chartInvalidValue("dimensions", "维度不能为空")
        }
        let dimensionNames = ArrayList<String>()
        let minValues = ArrayList<Option<Float64>>()
        let maxValues = ArrayList<Option<Float64>>()
        var dimensionIndex = 0
        for (item in dimensionItems) {
            let path = "dimensions[${dimensionIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望 {name,min,max} 对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            dimensionNames.add(json.string("name", default: "D${dimensionIndex + 1}"))
            minValues.add(json.number("min"))
            maxValues.add(json.number("max"))
            dimensionIndex++
        }
        let dimensionCount = dimensionNames.size

        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<ParallelSeriesData>()
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
                if (values.size != dimensionCount) {
                    throw chartInvalidValue(
                        rowPath,
                        "行长度 ${values.size} 与维度数 ${dimensionCount} 不一致"
                    )
                }
                rows.add(values.toArray())
                rowIndex++
            }
            series.add(ParallelSeriesData(name, color, rows.toArray()))
            seriesIndex++
        }

        let dimensions = ArrayList<ParallelDimension>()
        for (index in 0..dimensionCount) {
            var minimum = 0.0
            var maximum = 1.0
            var hasData = false
            for (item in series) {
                for (row in item.rows) {
                    if (!hasData) {
                        minimum = row[index]
                        maximum = row[index]
                        hasData = true
                    } else {
                        minimum = minFloat(minimum, row[index])
                        maximum = maxFloat(maximum, row[index])
                    }
                }
            }
            let explicitMin = match (minValues[index]) {
                case Some(value) => value
                case None => minimum
            }
            let explicitMax = match (maxValues[index]) {
                case Some(value) => value
                case None => maximum
            }
            if (explicitMax <= explicitMin) {
                if (minValues[index].isSome() && maxValues[index].isSome()) {
                    throw chartInvalidValue(
                        "dimensions[${index}]",
                        "维度范围必须递增"
                    )
                }
                if (explicitMax == explicitMin) {
                    minimum = explicitMin - 0.5
                    maximum = explicitMax + 0.5
                } else {
                    throw chartInvalidValue(
                        "dimensions[${index}]",
                        "维度范围必须递增"
                    )
                }
            } else {
                minimum = explicitMin
                maximum = explicitMax
            }
            dimensions.add(ParallelDimension(dimensionNames[index], minimum, maximum))
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

        let left = config.padding.left + 60.0
        let right = config.width - config.padding.right - 20.0
        let top = config.padding.top + 64.0
        let bottom = config.height - config.padding.bottom - 40.0
        let step = if (dimensionCount == 1) {
            0.0
        } else {
            (right - left) / Float64(dimensionCount - 1)
        }
        for (index in 0..dimensionCount) {
            let x = if (dimensionCount == 1) {
                (left + right) / 2.0
            } else {
                left + Float64(index) * step
            }
            kit.line(
                x, top, x, bottom,
                stroke: config.theme.axisColor, strokeWidth: 1.0, className: "dimension-axis"
            )
            kit.text(
                x, top - 10.0, dimensions[index].name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "dimension-label"
            )
            kit.text(
                x, bottom + 16.0, chartFormatTick(dimensions[index].minimum, config.yAxis.labelFormat),
                size: config.theme.fontSize - 1.0,
                color: config.theme.axisColor,
                anchor: "middle",
                className: "dimension-tick"
            )
            kit.text(
                x, top - 26.0, chartFormatTick(dimensions[index].maximum, config.yAxis.labelFormat),
                size: config.theme.fontSize - 1.0,
                color: config.theme.axisColor,
                anchor: "middle",
                className: "dimension-tick"
            )
        }

        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            for (row in item.rows) {
                let path = StringBuilder()
                for (index in 0..dimensionCount) {
                    let x = if (dimensionCount == 1) {
                        (left + right) / 2.0
                    } else {
                        left + Float64(index) * step
                    }
                    let normalized = parallelNormalize(
                        row[index], dimensions[index].minimum, dimensions[index].maximum
                    )
                    let y = bottom - normalized * (bottom - top)
                    if (index == 0) {
                        path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    } else {
                        path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                    }
                }
                kit.path(
                    path.toString(), fill: "none", stroke: color, strokeWidth: 1.5,
                    className: "parallel-line"
                )
            }
        }
        builder.toSvgString()
    }
}

/** 维度归一化到 [0,1]。 */
internal func parallelNormalize(value: Float64, minimum: Float64, maximum: Float64): Float64 {
    if (maximum <= minimum) {
        0.0
    } else {
        let ratio = (value - minimum) / (maximum - minimum)
        if (ratio < 0.0) {
            0.0
        } else if (ratio > 1.0) {
            1.0
        } else {
            ratio
        }
    }
}
