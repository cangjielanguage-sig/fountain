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

/** 圆堆积图节点。 */
internal class CirclePackingNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let ownValue: Option<Float64>
    let children: ArrayList<CirclePackingNode>
    var total: Float64
    var x: Float64
    var y: Float64
    var radius: Float64

    init(id: String, name: String, parentId: Option<String>, ownValue: Option<Float64>) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.ownValue = ownValue
        this.children = ArrayList<CirclePackingNode>()
        this.total = 0.0
        this.x = 0.0
        this.y = 0.0
        this.radius = 0.0
    }
}

/** M70 圆堆积图。 */
public class CirclePackingChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "circle-packing")
        let root = ChartJson.of(data)
        let padding = root.number("padding", default: 2.0)
        if (padding < 0.0) {
            throw chartInvalidValue("padding", "padding 不能为负")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<CirclePackingNode>()
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
            nodes.add(CirclePackingNode(
                id, json.string("name", default: id), parentId, json.number("value")
            ))
            nodeIndex++
        }

        let roots = ArrayList<CirclePackingNode>()
        for (node in nodes) {
            match (node.parentId) {
                case Some(parentId) =>
                    match (findNode(nodes, parentId)) {
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
        resolveTotals(rootNode, 0, nodes.size)
        sortChildren(rootNode, 0, nodes.size)

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let scale = minFloat(frame.plot.width, frame.plot.height) * 0.45 /
            sqrt(rootNode.total)
        rootNode.x = frame.plot.centerX()
        rootNode.y = frame.plot.centerY()
        rootNode.radius = circlePackingRadius(rootNode.total, scale)
        layoutChildren(rootNode, scale, padding, 0, nodes.size)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        drawNode(kit, config, rootNode)
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<CirclePackingNode>, id: String): ?CirclePackingNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<CirclePackingNode>
    }

    private func resolveTotals(node: CirclePackingNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        if (node.children.isEmpty()) {
            match (node.ownValue) {
                case Some(value) =>
                    if (value <= 0.0) {
                        throw chartInvalidValue("nodes", "叶子节点 ${node.id} 的值必须大于 0")
                    }
                    node.total = value
                case None =>
                    throw chartInvalidValue("nodes", "叶子节点 ${node.id} 缺少 value")
            }
            return
        }
        var sum = 0.0
        for (child in node.children) {
            resolveTotals(child, depth + 1, total)
            sum += child.total
        }
        node.total = sum
    }

    private func sortChildren(node: CirclePackingNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        if (node.children.size > 1) {
            for (i in 1..node.children.size) {
                var j = i
                while (j > 0 && node.children[j].total > node.children[j - 1].total) {
                    let temporary = node.children[j]
                    node.children[j] = node.children[j - 1]
                    node.children[j - 1] = temporary
                    j--
                }
            }
        }
        for (child in node.children) {
            sortChildren(child, depth + 1, total)
        }
    }

    private func layoutChildren(
        node: CirclePackingNode,
        scale: Float64,
        padding: Float64,
        depth: Int64,
        total: Int64
    ): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        if (node.children.isEmpty()) {
            return
        }
        let count = node.children.size
        let columns = Int64(ceil(sqrt(Float64(count))))
        let rows = (count + columns - 1) / columns
        let cellWidth = 2.0 * node.radius / Float64(columns)
        let cellHeight = 2.0 * node.radius / Float64(rows)
        for (index in 0..count) {
            let child = node.children[index]
            let column = index % columns
            let row = index / columns
            child.x = node.x - node.radius + (Float64(column) + 0.5) * cellWidth
            child.y = node.y - node.radius + (Float64(row) + 0.5) * cellHeight
            let maxRadius = minFloat(cellWidth, cellHeight) / 2.0 - padding
            let desired = circlePackingRadius(child.total, scale)
            child.radius = if (maxRadius <= 0.0) { 0.0 } else { minFloat(desired, maxRadius) }
            layoutChildren(child, scale, padding, depth + 1, total)
        }
    }

    private func drawNode(kit: ChartSvgKit, config: ChartConfig, node: CirclePackingNode): Unit {
        if (node.radius > 0.0) {
            let color = config.theme.colorAt(
                flameColorIndex(node.name, config.theme.palette.size)
            )
            kit.circle(node.x, node.y, node.radius, fill: color, className: "circle-packing-circle")
            if (node.radius >= 18.0) {
                kit.text(
                    node.x, node.y, node.name,
                    size: minFloat(config.theme.fontSize, node.radius / 2.0),
                    color: "#ffffff",
                    anchor: "middle",
                    className: "circle-packing-label"
                )
            }
        }
        for (child in node.children) {
            drawNode(kit, config, child)
        }
    }
}

/** 面积半径：`sqrt(value) * scale`。 */
internal func circlePackingRadius(value: Float64, scale: Float64): Float64 {
    if (value <= 0.0) {
        return 0.0
    }
    sqrt(value) * scale
}
