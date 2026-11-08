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

/** 离线火焰图节点。 */
internal class OfflineFlameNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let value: Float64
    let children: ArrayList<OfflineFlameNode>
    var depth: Int64
    var x: Float64
    var width: Float64

    init(id: String, name: String, parentId: Option<String>, value: Float64) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.value = value
        this.children = ArrayList<OfflineFlameNode>()
        this.depth = 0
        this.x = 0.0
        this.width = 0.0
    }
}

/** M55 离线火焰图：只展示指定子树，可限制深度。 */
public class OfflineFlameChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "offline-flame")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        let items = nodesArray.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let parsed = ArrayList<OfflineFlameNode>()
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
            parsed.add(OfflineFlameNode(id, name, parentId, value))
            index++
        }
        let roots = ArrayList<OfflineFlameNode>()
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
        validateValues(roots[0], 0, parsed.size)

        let rootId = root.string("root")
        let selected = match (rootId) {
            case Some(id) =>
                match (findNode(parsed, id)) {
                    case Some(node) => node
                    case None => throw chartInvalidValue("root", "根节点 ${id} 不存在")
                }
            case None => roots[0]
        }
        assignDepth(selected, 0, parsed.size)

        var maxDepth: Int64 = -1
        match (root.number("maxDepth")) {
            case Some(value) =>
                if (value < 0.0 || value != floor(value)) {
                    throw chartInvalidValue("maxDepth", "maxDepth 必须为非负整数")
                }
                maxDepth = Int64(value)
            case None => ()
        }

        var naturalDepth = selected.depth
        for (node in parsed) {
            naturalDepth = if (node.depth > naturalDepth) { node.depth } else { naturalDepth }
        }
        let visibleDepth = if (maxDepth >= 0 && maxDepth < naturalDepth) {
            maxDepth
        } else {
            naturalDepth
        }
        let frame = ChartFrame(config, false, 0.0, 0.0)
        var frameHeight = 18.0
        let fitHeight = frame.plot.height / Float64(visibleDepth + 1)
        if (fitHeight < frameHeight) {
            frameHeight = fitHeight
        }
        if (frameHeight < 1.0) {
            frameHeight = 1.0
        }
        layoutNode(selected, frame.plot.x, selected.value, frame.plot.width)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        drawNode(kit, config, selected, frameHeight, maxDepth, frame)
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<OfflineFlameNode>, id: String): ?OfflineFlameNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<OfflineFlameNode>
    }

    private func validateValues(node: OfflineFlameNode, depth: Int64, total: Int64): Unit {
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

    private func assignDepth(node: OfflineFlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        node.depth = depth
        for (child in node.children) {
            assignDepth(child, depth + 1, total)
        }
    }

    private func layoutNode(
        node: OfflineFlameNode,
        x: Float64,
        rootValue: Float64,
        plotWidth: Float64
    ): Unit {
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
        node: OfflineFlameNode,
        frameHeight: Float64,
        maxDepth: Int64,
        frame: ChartFrame
    ): Unit {
        if (maxDepth >= 0 && node.depth > maxDepth) {
            return
        }
        let color = config.theme.colorAt(flameColorIndex(node.name, config.theme.palette.size))
        let y = frame.plot.bottom() - (Float64(node.depth) + 1.0) * frameHeight
        kit.rect(
            node.x, y, node.width, frameHeight,
            fill: color, stroke: "#ffffff", strokeWidth: 1.0,
            className: "offline-flame-node"
        )
        let fontSize = config.theme.fontSize - 2.0
        if (node.width > chartTextWidth(node.name, fontSize) + 6.0) {
            kit.text(
                node.x + 4.0, y + frameHeight / 2.0,
                node.name,
                size: fontSize,
                color: config.theme.textColor,
                className: "offline-flame-label"
            )
        }
        for (child in node.children) {
            drawNode(kit, config, child, frameHeight, maxDepth, frame)
        }
    }
}
