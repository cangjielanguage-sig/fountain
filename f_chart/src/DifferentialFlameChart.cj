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

/** 差分火焰图节点。 */
internal class DiffFlameNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let value1: Float64
    let value2: Float64
    let children: ArrayList<DiffFlameNode>
    var depth: Int64
    var x: Float64
    var width: Float64

    init(id: String, name: String, parentId: Option<String>, value1: Float64, value2: Float64) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.value1 = value1
        this.value2 = value2
        this.children = ArrayList<DiffFlameNode>()
        this.depth = 0
        this.x = 0.0
        this.width = 0.0
    }
}

/** M54 差分火焰图：红色增加、蓝色减少。 */
public class DifferentialFlameChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "differential-flame")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        let items = nodesArray.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let parsed = ArrayList<DiffFlameNode>()
        var maxAbsDelta = 0.0
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
            let value1 = jsonNumberValue(json.required("value1"), "${itemPath}.value1")
            let value2 = jsonNumberValue(json.required("value2"), "${itemPath}.value2")
            if (value1 < 0.0 || value2 < 0.0) {
                throw chartInvalidValue("${itemPath}.value1", "节点值不能为负")
            }
            if (value1 <= 0.0 && value2 <= 0.0) {
                throw chartInvalidValue("${itemPath}.value2", "节点值至少一个大于 0")
            }
            maxAbsDelta = maxFloat(maxAbsDelta, abs(value2 - value1))
            parsed.add(DiffFlameNode(id, name, parentId, value1, value2))
            index++
        }
        let roots = ArrayList<DiffFlameNode>()
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
            default: ["#4a90d9", "#e53935"]
        )
        if (colorRange.size != 2 && colorRange.size != 3) {
            throw chartInvalidValue("colorRange", "期望两个或三个颜色")
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
        let rootWidth = if (rootNode.value2 > 0.0) { rootNode.value2 } else { rootNode.value1 }
        layoutNode(rootNode, frame.plot.x, rootWidth, frame.plot.width)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        drawNode(
            kit, config, rootNode, frameHeight, maxAbsDelta, colorRange, frame
        )
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<DiffFlameNode>, id: String): ?DiffFlameNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<DiffFlameNode>
    }

    private func validateValues(node: DiffFlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        var child1 = 0.0
        var child2 = 0.0
        for (child in node.children) {
            child1 += child.value1
            child2 += child.value2
        }
        if (node.children.size > 0 &&
            (child1 > node.value1 + 1e-6 || child2 > node.value2 + 1e-6)) {
            throw chartInvalidValue("nodes", "节点 ${node.id} 的值小于子节点之和")
        }
        for (child in node.children) {
            validateValues(child, depth + 1, total)
        }
    }

    private func assignDepth(node: DiffFlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        node.depth = depth
        for (child in node.children) {
            assignDepth(child, depth + 1, total)
        }
    }

    private func layoutNode(node: DiffFlameNode, x: Float64, rootWidth: Float64, plotWidth: Float64): Unit {
        node.x = x
        node.width = node.value2 / rootWidth * plotWidth
        var childX = x
        for (child in node.children) {
            layoutNode(child, childX, rootWidth, plotWidth)
            childX += child.width
        }
    }

    private func drawNode(
        kit: ChartSvgKit,
        config: ChartConfig,
        node: DiffFlameNode,
        frameHeight: Float64,
        maxAbsDelta: Float64,
        colorRange: Array<String>,
        frame: ChartFrame
    ): Unit {
        let delta = node.value2 - node.value1
        let color = differentialColor(delta, maxAbsDelta, colorRange)
        let y = frame.plot.bottom() - (Float64(node.depth) + 1.0) * frameHeight
        kit.rect(
            node.x, y, node.width, frameHeight,
            fill: color, stroke: "#ffffff", strokeWidth: 1.0,
            className: "diff-flame-node"
        )
        let fontSize = config.theme.fontSize - 2.0
        if (node.width > chartTextWidth(node.name, fontSize) + 6.0) {
            let intensity = if (maxAbsDelta <= 0.0) {
                0.0
            } else {
                abs(delta) / maxAbsDelta
            }
            kit.text(
                node.x + 4.0, y + frameHeight / 2.0,
                node.name,
                size: fontSize,
                color: if (intensity >= 0.6) { "#ffffff" } else { config.theme.textColor },
                className: "diff-flame-label"
            )
        }
        for (child in node.children) {
            drawNode(kit, config, child, frameHeight, maxAbsDelta, colorRange, frame)
        }
    }
}

/** 差值 → 颜色：正为增加色、负为减少色、0 为中性色。 */
internal func differentialColor(delta: Float64, maxAbsDelta: Float64, colors: Array<String>): String {
    var down = "#4a90d9"
    var neutral = "#f0f0f0"
    var up = "#e53935"
    if (colors.size >= 3) {
        down = colors[0]
        neutral = colors[1]
        up = colors[2]
    } else if (colors.size == 2) {
        down = colors[0]
        up = colors[1]
    }
    if (maxAbsDelta <= 0.0 || delta == 0.0) {
        return neutral
    }
    if (delta > 0.0) {
        let ratio = minFloat(delta / maxAbsDelta, 1.0)
        heatmapColor(ratio, neutral, neutral, up)
    } else {
        let ratio = minFloat(-delta / maxAbsDelta, 1.0)
        heatmapColor(ratio, neutral, neutral, down)
    }
}
