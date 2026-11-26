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

/** 华夫图的一个类别。 */
internal class WaffleCategory {
    let name: String
    let value: Float64

    init(name: String, value: Float64) {
        this.name = name
        this.value = value
    }
}

/** M73 华夫图。 */
public class WaffleChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "waffle")
        let root = ChartJson.of(data)
        let cellsValue = root.number("cells", default: 100.0)
        if (cellsValue < 1.0 || cellsValue != floor(cellsValue)) {
            throw chartInvalidValue("cells", "总格数必须为正整数")
        }
        let columnsValue = root.number("columns", default: 10.0)
        if (columnsValue < 1.0 || columnsValue != floor(columnsValue)) {
            throw chartInvalidValue("columns", "列数必须为正整数")
        }
        let cells = Int64(cellsValue)
        let columns = Int64(columnsValue)

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "华夫图仅支持 1 个系列")
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
        let categories = ArrayList<WaffleCategory>()
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
                throw chartInvalidValue("${itemPath}.value", "数值不能为负")
            }
            categories.add(WaffleCategory(name, value))
            values.add(value)
            index++
        }
        let counts = waffleCellCounts(values.toArray(), cells)

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let plot = frame.plot
        let legendHeight = 28.0
        let gridHeight = plot.height - legendHeight
        let rows = (cells + columns - 1) / columns
        let gap = 2.0
        let cellSize = minFloat(
            (plot.width - gap * Float64(columns - 1)) / Float64(columns),
            (gridHeight - gap * Float64(rows - 1)) / Float64(rows)
        )
        let cell = maxFloat(cellSize, 1.0)
        let gridWidth = cell * Float64(columns) + gap * Float64(columns - 1)
        let gridHeightActual = cell * Float64(rows) + gap * Float64(rows - 1)
        let originX = plot.x + (plot.width - gridWidth) / 2.0
        let originY = plot.y + (gridHeight - gridHeightActual) / 2.0

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        var cellIndex: Int64 = 0
        for (categoryIndex in 0..counts.size) {
            let color = config.theme.colorAt(categoryIndex)
            var filled: Int64 = 0
            while (filled < counts[categoryIndex] && cellIndex < cells) {
                let row = cellIndex / columns
                let column = cellIndex % columns
                kit.rect(
                    originX + Float64(column) * (cell + gap),
                    originY + Float64(row) * (cell + gap),
                    cell,
                    cell,
                    fill: color,
                    className: "waffle-cell",
                    radius: 1.5
                )
                cellIndex++
                filled++
            }
        }

        var legendX = plot.x
        var legendY = plot.y + gridHeight + 16.0
        for (categoryIndex in 0..categories.size) {
            let category = categories[categoryIndex]
            let label = "${category.name} ${formatSvgNumber(category.value)}"
            let width = chartTextWidth(label, config.theme.fontSize) + 24.0
            if (legendX + width > plot.right() && legendX > plot.x) {
                legendX = plot.x
                legendY += 18.0
            }
            kit.rect(
                legendX,
                legendY - 9.0,
                10.0,
                10.0,
                fill: config.theme.colorAt(categoryIndex),
                className: "waffle-swatch",
                radius: 1.5
            )
            kit.text(
                legendX + 14.0,
                legendY,
                label,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                className: "waffle-legend"
            )
            legendX += width
        }
        builder.toSvgString()
    }
}

/** 用最大余数法把占比换算为整数格，返回数组之和等于 `cells`。 */
internal func waffleCellCounts(values: Array<Float64>, cells: Int64): Array<Int64> {
    var total = 0.0
    for (value in values) {
        if (value < 0.0) {
            throw chartInvalidValue("series[0].data", "数值不能为负")
        }
        total += value
    }
    if (total <= 0.0) {
        throw chartInvalidValue("series[0].data", "数值总和必须大于 0")
    }
    let counts = ArrayList<Int64>()
    let remainders = ArrayList<Float64>()
    var assigned: Int64 = 0
    for (value in values) {
        let exact = value / total * Float64(cells)
        let base = Int64(floor(exact))
        counts.add(base)
        remainders.add(exact - Float64(base))
        assigned += base
    }
    var remaining = cells - assigned
    while (remaining > 0) {
        var best = 0
        var bestRemainder = remainders[0]
        for (index in 1..remainders.size) {
            if (remainders[index] > bestRemainder) {
                bestRemainder = remainders[index]
                best = index
            }
        }
        counts[best] = counts[best] + 1
        remainders[best] = -1.0
        remaining--
    }
    counts.toArray()
}
