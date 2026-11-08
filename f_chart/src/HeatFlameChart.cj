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

/** 热火焰图节点。 */
internal class HeatFlameNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let value: Float64
    let heat: Float64
    let children: ArrayList<HeatFlameNode>
    var depth: Int64
    var x: Float64
    var width: Float64

    init(id: String, name: String, parentId: Option<String>, value: Float64, heat: Float64) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.value = value
        this.heat = heat
        this.children = ArrayList<HeatFlameNode>()
        this.depth = 0
        this.x = 0.0
        this.width = 0.0
    }
}

/** M56 热火焰图：节点颜色编码热度字段。 */
public class HeatFlameChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "heat-flame")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        let items = nodesArray.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let heatField = root.string("heatField", default: "self")
        if (heatField.isEmpty()) {
            throw chartInvalidValue("heatField", "字段名不能为空")
        }
        let parsed = ArrayList<HeatFlameNode>()
        var maxHeat = 0.0
        var index = 0
        for (item in items) {
            let itemPath = "nodes[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望节点对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let idJson = json.required("id")
            if (!idJson.kind.isString) {
                throw chartInvalidValue("${itemPath}.id", "期望字符串")
            }
            let id = idJson.asString().value
            for (existing in parsed) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "节点 id 重复")
                }
            }
            let name = json.string("name", default: id)
            let parentId = match (json.value("parent")) {
                case Some(entry) =>
                    if (entry.kind.isNull) {
                        None<String>
                    } else if (entry.kind.isString) {
                        Some(entry.asString().value)
                    } else {
                        throw chartInvalidValue("${itemPath}.parent", "期望字符串或 null")
                    }
                case None => None<String>
            }
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "节点值必须大于 0")
            }
            let heat = match (json.number(heatField)) {
                case Some(numeric) =>
                    if (numeric < 0.0) {
                        throw chartInvalidValue("${itemPath}.${heatField}", "热度不能为负")
                    }
                    numeric
                case None => 0.0
            }
            maxHeat = maxFloat(maxHeat, heat)
            parsed.add(HeatFlameNode(id, name, parentId, value, heat))
            index++
        }
        let roots = ArrayList<HeatFlameNode>()
        for (node in parsed) {
            match (node.parentId) {
                case Some(parentId) =>
                    match (findNode(parsed, parentId)) {
                        case Some(parentNode) => parentNode.children.add(node)
                        case None =>
                            throw chartInvalidValue("nodes", "父节点 ${parentId} 不存在")
                    }
                case None => roots.add(node)
            }
        }
        if (roots.size != 1) {
            throw chartInvalidValue("nodes", "必须恰好有一个根节点")
        }
        let rootNode = roots[0]
        validateValues(rootNode, 0, parsed.size)
        assignDepth(rootNode, 0, parsed.size)

        let colorRange = root.stringArray(
            "colorRange",
            default: ["#ffffcc", "#fd8d3c", "#800026"]
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
        let configuredHeight = root.number("frameHeight", default: 18.0)
        if (configuredHeight <= 0.0) {
            throw chartInvalidValue("frameHeight", "层高必须大于 0")
        }

        var maxDepth = rootNode.depth
        for (node in parsed) {
            maxDepth = if (node.depth > maxDepth) { node.depth } else { maxDepth }
        }
        let frame = ChartFrame(config, false, 0.0, 0.0)
        var frameHeight = configuredHeight
        let fitHeight = frame.plot.height / Float64(maxDepth + 1)
        if (fitHeight < frameHeight) {
            frameHeight = fitHeight
        }
        if (frameHeight < 1.0) {
            frameHeight = 1.0
        }
        layoutNode(rootNode, frame.plot.x, rootNode.value, frame.plot.width)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        drawNode(kit, config, rootNode, maxHeat, frameHeight, colorRange, frame)
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<HeatFlameNode>, id: String): ?HeatFlameNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<HeatFlameNode>
    }

    private func validateValues(node: HeatFlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        var childTotal = 0.0
        for (child in node.children) {
            childTotal += child.value
        }
        if (node.children.size > 0 && childTotal > node.value + 1e-6) {
            throw chartInvalidValue("nodes", "节点 ${node.id} 的值小于子节点之和")
        }
        for (child in node.children) {
            validateValues(child, depth + 1, total)
        }
    }

    private func assignDepth(node: HeatFlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        node.depth = depth
        for (child in node.children) {
            assignDepth(child, depth + 1, total)
        }
    }

    private func layoutNode(node: HeatFlameNode, x: Float64, rootValue: Float64, plotWidth: Float64): Unit {
        node.x = x
        node.width = node.value / rootValue * plotWidth
        var childX = x
        for (child in node.children) {
            layoutNode(child, childX, rootValue, plotWidth)
            childX += child.width
        }
    }

    private func drawNode(
        kit: ChartSvgKit,
        config: ChartConfig,
        node: HeatFlameNode,
        maxHeat: Float64,
        frameHeight: Float64,
        colorRange: Array<String>,
        frame: ChartFrame
    ): Unit {
        let ratio = if (maxHeat <= 0.0) { 0.0 } else { node.heat / maxHeat }
        let color = heatFlameColor(ratio, colorRange)
        let y = frame.plot.bottom() - (Float64(node.depth) + 1.0) * frameHeight
        kit.rect(
            node.x, y, node.width, frameHeight,
            fill: color, stroke: "#ffffff", strokeWidth: 1.0,
            className: "heat-flame-node"
        )
        let fontSize = config.theme.fontSize - 2.0
        if (node.width > chartTextWidth(node.name, fontSize) + 6.0) {
            kit.text(
                node.x + 4.0, y + frameHeight / 2.0,
                node.name,
                size: fontSize,
                color: if (ratio >= 0.6) { "#ffffff" } else { config.theme.textColor },
                className: "heat-flame-label"
            )
        }
        for (child in node.children) {
            drawNode(kit, config, child, maxHeat, frameHeight, colorRange, frame)
        }
    }
}

/** 热度比例 → 颜色：两色线性插值，三色及以上复用 heatmapColor。 */
internal func heatFlameColor(ratio: Float64, colors: Array<String>): String {
    if (colors.isEmpty()) {
        return "#ffffcc"
    }
    var value = ratio
    if (value < 0.0) {
        value = 0.0
    }
    if (value > 1.0) {
        value = 1.0
    }
    if (colors.size >= 3) {
        return heatmapColor(value, colors[0], colors[1], colors[2])
    }
    if (colors.size == 1) {
        return colors[0]
    }
    let cold = parseHeatFlameColor(colors[0], "colorRange[0]")
    let warm = parseHeatFlameColor(colors[1], "colorRange[1]")
    let red = mixHeatFlameChannel(cold.red, warm.red, value)
    let green = mixHeatFlameChannel(cold.green, warm.green, value)
    let blue = mixHeatFlameChannel(cold.blue, warm.blue, value)
    SvgColor.fromRgb(red, green, blue).toString()
}

private func parseHeatFlameColor(text: String, path: String): SvgColor {
    match (SvgColor.tryParse(text)) {
        case Some(color) => color
        case None => throw chartInvalidValue(path, "非法颜色 ${text}")
    }
}

private func mixHeatFlameChannel(from: UInt8, to: UInt8, ratio: Float64): UInt8 {
    let start = Float64(Int64(from))
    let end = Float64(Int64(to))
    UInt8(Int64(round(start + (end - start) * ratio)))
}
