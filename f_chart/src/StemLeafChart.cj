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

/** 茎叶图的一行。 */
internal class StemLeafRow {
    let stem: Int64
    let leaves: Array<Int64>

    init(stem: Int64, leaves: Array<Int64>) {
        this.stem = stem
        this.leaves = leaves
    }
}

/**
 * M22 茎叶图。
 *
 * 按 `stemUnit` 分组、`leafDigits` 截取叶，以文本行展示原始分布。
 */
public class StemLeafChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "stem-leaf")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "茎叶图仅支持 1 个系列")
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
        let values = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!(item.kind.isInt || item.kind.isDecimal)) {
                throw chartInvalidValue(itemPath, "期望数字")
            }
            values.add(jsonNumberValue(item, itemPath))
            index++
        }

        let stemUnit = root.number("stemUnit", default: 10.0)
        if (stemUnit <= 0.0 || stemUnit.isNaN() || stemUnit.isInf()) {
            throw chartInvalidValue("stemUnit", "茎单位必须大于 0")
        }
        let rawDigits = root.number("leafDigits", default: 1.0)
        if (rawDigits < 0.0 || rawDigits != floor(rawDigits) || rawDigits > 6.0) {
            throw chartInvalidValue("leafDigits", "叶位数必须为 0 到 6 的整数")
        }
        let rows = stemLeafRows(values.toArray(), stemUnit, Int64(rawDigits))

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        let centerX = config.width / 2.0
        var y = config.padding.top + config.theme.fontSize + 8.0
        if (!config.title.isEmpty()) {
            kit.text(
                centerX, y, config.title,
                size: config.titleFontSize,
                color: config.titleColor,
                anchor: "middle",
                className: "title"
            )
            y += config.titleFontSize + 16.0
        }
        let left = config.padding.left + 24.0
        let rowHeight = config.theme.fontSize + 8.0
        kit.text(
            left, y, "茎 | 叶",
            size: config.theme.fontSize,
            color: config.theme.textColor,
            className: "stem-leaf-header"
        )
        y += rowHeight
        for (row in rows) {
            kit.text(
                left + 40.0, y, row.stem.toString(),
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "stem-leaf-row"
            )
            kit.text(
                left + 50.0, y, "|",
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                className: "stem-leaf-separator"
            )
            let leaves = StringBuilder()
            for (leafIndex in 0..row.leaves.size) {
                if (leafIndex > 0) {
                    leaves.append(" ")
                }
                leaves.append(row.leaves[leafIndex].toString())
            }
            kit.text(
                left + 62.0, y, leaves.toString(),
                size: config.theme.fontSize,
                color: config.theme.textColor,
                className: "stem-leaf-leaves"
            )
            y += rowHeight
        }
        builder.toSvgString()
    }
}

/** 按茎分组并排序；叶钳制在 `[0, 10^leafDigits-1]`。 */
internal func stemLeafRows(
    values: Array<Float64>,
    stemUnit: Float64,
    leafDigits: Int64
): Array<StemLeafRow> {
    if (values.isEmpty()) {
        throw chartInvalidValue("series[0].data", "数据不能为空")
    }
    if (stemUnit <= 0.0 || stemUnit.isNaN() || stemUnit.isInf()) {
        throw chartInvalidValue("stemUnit", "茎单位必须大于 0")
    }
    if (leafDigits < 0 || leafDigits > 6) {
        throw chartInvalidValue("leafDigits", "叶位数必须为 0 到 6 的整数")
    }
    let sorted = ArrayList<Float64>()
    for (value in values) {
        sorted.add(value)
    }
    for (i in 1..sorted.size) {
        var j = i
        while (j > 0 && sorted[j] < sorted[j - 1]) {
            let temporary = sorted[j]
            sorted[j] = sorted[j - 1]
            sorted[j - 1] = temporary
            j--
        }
    }
    let leafUnit = stemUnit / pow(10.0, Float64(leafDigits))
    let leafCount = Int64(pow(10.0, Float64(leafDigits)))
    let rows = ArrayList<StemLeafRow>()
    var currentStem = 0
    var currentLeaves = ArrayList<Int64>()
    var hasRow = false
    for (value in sorted) {
        let stem = Int64(floor(value / stemUnit))
        var leaf = Int64(round((value - Float64(stem) * stemUnit) / leafUnit))
        if (leaf < 0) {
            leaf = 0
        }
        if (leaf >= leafCount) {
            leaf = leafCount - 1
        }
        if (!hasRow || stem != currentStem) {
            if (hasRow) {
                rows.add(StemLeafRow(currentStem, currentLeaves.toArray()))
            }
            currentStem = stem
            currentLeaves = ArrayList<Int64>()
            currentLeaves.add(leaf)
            hasRow = true
        } else {
            currentLeaves.add(leaf)
        }
    }
    if (hasRow) {
        rows.add(StemLeafRow(currentStem, currentLeaves.toArray()))
    }
    rows.toArray()
}
