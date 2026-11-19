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

/** 网络热力图节点。 */
internal class NetworkHeatmapNode {
    let id: String
    let name: String

    init(id: String, name: String) {
        this.id = id
        this.name = name
    }
}

/** M68 网络热力图。 */
public class NetworkHeatmapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "network-heatmap")
        let root = ChartJson.of(data)
        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<NetworkHeatmapNode>()
        var nodeIndex = 0
        for (item in nodeItems) {
            let itemPath = "nodes[${nodeIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望节点对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let id = json.requiredString("id")
            for (existing in nodes) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "节点 id 重复")
                }
            }
            nodes.add(NetworkHeatmapNode(id, json.string("name", default: id)))
            nodeIndex++
        }
        let order = nodes.size

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "网络热力图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.size != order) {
            throw chartInvalidValue(
                "series[0].data",
                "矩阵阶数 ${items.size} 与节点数 ${order} 不一致"
            )
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
            if (rowItems.size != order) {
                throw chartInvalidValue(
                    rowPath,
                    "行长度 ${rowItems.size} 与节点数 ${order} 不一致"
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

        let colorRange = root.stringArray(
            "colorRange",
            default: ["#f7fbff", "#6baed6", "#08306b"]
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
        let showValues = root.bool("showValues", default: false)
        let cellGap = root.number("cellGap", default: 1.0)
        if (cellGap < 0.0) {
            throw chartInvalidValue("cellGap", "单元格间隙不能为负")
        }

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
        var maxLabelWidth = 0.0
        for (node in nodes) {
            let width = chartTextWidth(node.name, config.theme.fontSize)
            if (width > maxLabelWidth) {
                maxLabelWidth = width
            }
        }
        let xLabelHeight = config.theme.fontSize + 12.0
        let frame = ChartFrame(config, legendVisible, maxLabelWidth + 14.0, xLabelHeight)
        let columnBand = BandScale(frame.plot.x, frame.plot.right(), order)
        let cellWidth = frame.plot.width / Float64(order)
        let cellHeight = frame.plot.height / Float64(order)

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
            [colorRange[colorRange.size / 2]]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)

        let span = maxValue - minValue
        for (row in 0..order) {
            for (column in 0..order) {
                let value = matrix[row][column]
                let ratio = if (span <= 0.0) { 0.5 } else { (value - minValue) / span }
                let x = frame.plot.x + Float64(column) * cellWidth + cellGap / 2.0
                let y = frame.plot.y + Float64(row) * cellHeight + cellGap / 2.0
                kit.rect(
                    x, y, cellWidth - cellGap, cellHeight - cellGap,
                    fill: heatFlameColor(ratio, colorRange),
                    className: "network-heatmap-cell"
                )
                if (showValues) {
                    kit.text(
                        x + (cellWidth - cellGap) / 2.0,
                        y + (cellHeight - cellGap) / 2.0,
                        chartFormatTick(value, "{value}"),
                        size: config.theme.fontSize,
                        color: if (ratio > 0.6) { "#ffffff" } else { config.theme.textColor },
                        anchor: "middle",
                        className: "network-heatmap-value"
                    )
                }
            }
        }

        kit.line(
            frame.plot.x, frame.plot.y, frame.plot.x, frame.plot.bottom(),
            stroke: config.theme.axisColor, strokeWidth: 1.0, className: "axis"
        )
        for (row in 0..order) {
            kit.text(
                frame.plot.x - 8.0,
                frame.plot.y + (Float64(row) + 0.5) * cellHeight,
                nodes[row].name,
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "tick-label"
            )
        }
        let labels = ArrayList<String>()
        for (node in nodes) {
            labels.add(node.name)
        }
        frame.drawXAxis(kit, labels.toArray(), columnBand)
        builder.toSvgString()
    }
}
