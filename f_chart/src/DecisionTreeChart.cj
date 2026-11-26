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

/** 决策树节点。 */
internal class DecisionNode {
    let id: String
    let label: String
    let leaf: Bool
    let children: ArrayList<DecisionNode>
    var depth: Int64
    var slot: Float64
    var x: Float64
    var y: Float64

    init(id: String, label: String, leaf: Bool) {
        this.id = id
        this.label = label
        this.leaf = leaf
        this.children = ArrayList<DecisionNode>()
        this.depth = 0
        this.slot = 0.0
        this.x = 0.0
        this.y = 0.0
    }
}

/** 决策树分支。 */
internal class DecisionEdge {
    let source: String
    let target: String
    let label: String

    init(source: String, target: String, label: String) {
        this.source = source
        this.target = target
        this.label = label
    }
}

/** 槽位游标。 */
internal class DecisionSlotCursor {
    var next: Float64 = 0.0
}

/** M99 决策树图。 */
public class DecisionTreeChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "decision-tree")
        let root = ChartJson.of(data)
        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<DecisionNode>()
        let parentOf = ArrayList<Option<String>>()
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
            let label = json.string("label", default: id)
            let leaf = json.bool("leaf", default: false)
            nodes.add(DecisionNode(id, label, leaf))
            let parent = match (json.value("parent")) {
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
            parentOf.add(parent)
            nodeIndex++
        }

        let edges = ArrayList<DecisionEdge>()
        match (root.value("edges")) {
            case Some(entry) =>
                if (!entry.kind.isArray) {
                    throw chartInvalidValue("edges", "期望数组")
                }
                var edgeIndex = 0
                for (item in entry.asArray().getItems()) {
                    let itemPath = "edges[${edgeIndex}]"
                    if (!item.kind.isObject) {
                        throw chartInvalidValue(itemPath, "期望分支对象")
                    }
                    let json = ChartJson.of(item.asObject(), itemPath)
                    let source = json.requiredString("source")
                    let target = json.requiredString("target")
                    if (findDecisionNode(nodes, source) < 0) {
                        throw chartInvalidValue("${itemPath}.source", "源节点 ${source} 不存在")
                    }
                    if (findDecisionNode(nodes, target) < 0) {
                        throw chartInvalidValue("${itemPath}.target", "目标节点 ${target} 不存在")
                    }
                    edges.add(DecisionEdge(source, target, json.string("label", default: "")))
                    edgeIndex++
                }
            case None => ()
        }

        if (!edges.isEmpty()) {
            let parentCounts = ArrayList<Int64>()
            for (index in 0..nodes.size) {
                parentCounts.add(0)
            }
            for (edge in edges) {
                let sourcePosition = findDecisionNode(nodes, edge.source)
                let targetPosition = findDecisionNode(nodes, edge.target)
                parentCounts[targetPosition] = parentCounts[targetPosition] + 1
                if (parentCounts[targetPosition] > 1) {
                    throw chartInvalidValue(
                        "edges", "节点 ${edge.target} 存在多个父节点"
                    )
                }
                let source = nodes[sourcePosition]
                let target = nodes[targetPosition]
                source.children.add(target)
            }
        } else {
            for (index in 0..nodes.size) {
                match (parentOf[index]) {
                    case Some(parentId) =>
                        let position = findDecisionNode(nodes, parentId)
                        if (position < 0) {
                            throw chartInvalidValue("nodes", "父节点 ${parentId} 不存在")
                        }
                        nodes[position].children.add(nodes[index])
                    case None => ()
                }
            }
        }

        let roots = ArrayList<DecisionNode>()
        for (node in nodes) {
            var hasParent = false
            for (candidate in nodes) {
                for (child in candidate.children) {
                    if (child.id == node.id) {
                        hasParent = true
                    }
                }
            }
            if (!hasParent) {
                roots.add(node)
            }
        }
        if (roots.size != 1) {
            throw chartInvalidValue("nodes", "必须恰好有一个根节点")
        }
        let rootNode = roots[0]
        let nodeArrayValue = nodes.toArray()
        if (countDecisionNodes(rootNode) != nodeArrayValue.size) {
            throw chartInvalidValue("edges", "决策树存在环或存在不可达节点")
        }

        let nodeWidth = 140.0
        let nodeHeight = 44.0
        let levelGap = 70.0
        decisionTreeLayout(nodeArrayValue, rootNode, nodeWidth, nodeHeight, levelGap)

        let frame = ChartFrame(config, false, 0.0, 0.0)
        var maxX = 0.0
        var maxY = 0.0
        for (node in nodeArrayValue) {
            maxX = maxFloat(maxX, node.x + nodeWidth)
            maxY = maxFloat(maxY, node.y + nodeHeight)
        }
        let dx = frame.plot.x + (frame.plot.width - maxX) / 2.0
        let dy = frame.plot.y + (frame.plot.height - maxY) / 2.0
        for (node in nodeArrayValue) {
            node.x += dx
            node.y += dy
        }

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        for (node in nodeArrayValue) {
            for (child in node.children) {
                let startX = node.x + nodeWidth / 2.0
                let startY = node.y + nodeHeight
                let endX = child.x + nodeWidth / 2.0
                let endY = child.y
                let midY = (startY + endY) / 2.0
                kit.path(
                    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                        " V ${formatSvgNumber(midY)} H ${formatSvgNumber(endX)}" +
                        " V ${formatSvgNumber(endY)}",
                    fill: "none",
                    stroke: config.theme.axisColor,
                    strokeWidth: 1.5,
                    className: "decision-edge"
                )
                let edgeLabel = decisionEdgeLabel(node.id, child.id, edges)
                if (!edgeLabel.isEmpty()) {
                    kit.text(
                        (startX + endX) / 2.0 + 4.0,
                        midY - 4.0,
                        edgeLabel,
                        size: config.theme.fontSize - 1.0,
                        color: config.theme.textColor,
                        className: "decision-edge-label"
                    )
                }
            }
        }

        for (node in nodeArrayValue) {
            let fill = if (node.leaf) { "#e8f5e9" } else { config.theme.colorAt(node.depth) }
            let textColor = if (node.leaf) { "#1b5e20" } else { "#ffffff" }
            let className = if (node.leaf) {
                "decision-node decision-leaf"
            } else {
                "decision-node"
            }
            kit.rect(
                node.x, node.y, nodeWidth, nodeHeight,
                fill: fill,
                stroke: "#ffffff",
                strokeWidth: 1.5,
                className: className,
                radius: 8.0
            )
            kit.text(
                node.x + nodeWidth / 2.0,
                node.y + nodeHeight / 2.0 + config.theme.fontSize / 3.0,
                orgFitLabel(node.label, nodeWidth - 12.0, config.theme.fontSize),
                size: config.theme.fontSize,
                color: textColor,
                anchor: "middle",
                className: "decision-node-label"
            )
        }
        builder.toSvgString()
    }
}

/** 按 id 查节点下标，未找到返回 −1。 */
internal func findDecisionNode(nodes: ArrayList<DecisionNode>, id: String): Int64 {
    for (index in 0..nodes.size) {
        if (nodes[index].id == id) {
            return index
        }
    }
    -1
}

/** 查找边的标签，未找到返回空串。 */
internal func decisionEdgeLabel(source: String, target: String, edges: ArrayList<DecisionEdge>): String {
    for (edge in edges) {
        if (edge.source == source && edge.target == target) {
            return edge.label
        }
    }
    ""
}

/** 统计从根可达的节点数。 */
internal func countDecisionNodes(root: DecisionNode): Int64 {
    var total: Int64 = 1
    for (child in root.children) {
        total += countDecisionNodes(child)
    }
    total
}

/** 递归设置深度。 */
internal func decisionAssignDepth(node: DecisionNode): Unit {
    for (child in node.children) {
        child.depth = node.depth + 1
        decisionAssignDepth(child)
    }
}

/** 递归分配槽位：叶子依次占槽，父节点取子节点中点。 */
internal func decisionAssignSlots(node: DecisionNode, cursor: DecisionSlotCursor): Unit {
    if (node.children.isEmpty()) {
        node.slot = cursor.next
        cursor.next += 1.0
        return
    }
    for (child in node.children) {
        decisionAssignSlots(child, cursor)
    }
    let first = node.children[0].slot
    let last = node.children[node.children.size - 1].slot
    node.slot = (first + last) / 2.0
}

/** 计算决策树节点相对坐标（从 0 开始）。 */
internal func decisionTreeLayout(
    nodes: Array<DecisionNode>,
    root: DecisionNode,
    nodeWidth: Float64,
    nodeHeight: Float64,
    levelGap: Float64
): Unit {
    root.depth = 0
    decisionAssignDepth(root)
    let cursor = DecisionSlotCursor()
    decisionAssignSlots(root, cursor)
    let gap = 20.0
    for (node in nodes) {
        node.x = node.slot * (nodeWidth + gap)
        node.y = Float64(node.depth) * (nodeHeight + levelGap)
    }
}
