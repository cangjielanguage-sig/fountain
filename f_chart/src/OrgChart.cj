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
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

/** 组织图节点。 */
internal class OrgNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let children: ArrayList<OrgNode>
    var depth: Int64
    var slot: Float64
    var x: Float64
    var y: Float64

    init(id: String, name: String, parentId: Option<String>) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.children = ArrayList<OrgNode>()
        this.depth = 0
        this.slot = 0.0
        this.x = 0.0
        this.y = 0.0
    }
}

/** 槽位分配游标。 */
internal class OrgSlotCursor {
    var next: Float64 = 0.0
}

/** M71 组织图 / 树状图。 */
public class OrgChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "org-chart")
        let root = ChartJson.of(data)
        let layout = root.string("layout", default: "vertical")
        if (layout != "vertical" && layout != "horizontal") {
            throw chartInvalidValue("layout", "仅支持 vertical 或 horizontal")
        }
        let nodeWidth = root.number("nodeWidth", default: 140.0)
        let nodeHeight = root.number("nodeHeight", default: 48.0)
        let levelGap = root.number("levelGap", default: 80.0)
        if (nodeWidth <= 0.0) {
            throw chartInvalidValue("nodeWidth", "节点宽度必须大于 0")
        }
        if (nodeHeight <= 0.0) {
            throw chartInvalidValue("nodeHeight", "节点高度必须大于 0")
        }
        if (levelGap < 0.0) {
            throw chartInvalidValue("levelGap", "层级间距不能为负")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<OrgNode>()
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
            nodes.add(OrgNode(id, json.string("name", default: id), parentId))
            nodeIndex++
        }

        let roots = ArrayList<OrgNode>()
        for (node in nodes) {
            match (node.parentId) {
                case Some(parentId) =>
                    match (findOrgNode(nodes, parentId)) {
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
        let nodeArrayValue = nodes.toArray()
        orgLayout(nodeArrayValue, rootNode, nodeWidth, nodeHeight, levelGap, layout == "horizontal")

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

        let horizontal = layout == "horizontal"
        for (node in nodeArrayValue) {
            for (child in node.children) {
                let path = if (horizontal) {
                    let startX = node.x + nodeWidth
                    let startY = node.y + nodeHeight / 2.0
                    let endX = child.x
                    let endY = child.y + nodeHeight / 2.0
                    let midX = (startX + endX) / 2.0
                    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                        " H ${formatSvgNumber(midX)} V ${formatSvgNumber(endY)}" +
                        " H ${formatSvgNumber(endX)}"
                } else {
                    let startX = node.x + nodeWidth / 2.0
                    let startY = node.y + nodeHeight
                    let endX = child.x + nodeWidth / 2.0
                    let endY = child.y
                    let midY = (startY + endY) / 2.0
                    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                        " V ${formatSvgNumber(midY)} H ${formatSvgNumber(endX)}" +
                        " V ${formatSvgNumber(endY)}"
                }
                kit.path(
                    path,
                    fill: None,
                    stroke: config.theme.axisColor,
                    strokeWidth: 1.5,
                    className: "org-link"
                )
            }
        }

        for (node in nodeArrayValue) {
            let fill = config.theme.colorAt(node.depth)
            kit.rect(
                node.x, node.y, nodeWidth, nodeHeight,
                fill: fill,
                stroke: "#ffffff",
                strokeWidth: 1.5,
                className: "org-node",
                radius: 4.0
            )
            kit.text(
                node.x + nodeWidth / 2.0,
                node.y + nodeHeight / 2.0 + config.theme.fontSize / 3.0,
                orgFitLabel(node.name, nodeWidth - 12.0, config.theme.fontSize),
                size: config.theme.fontSize,
                color: "#ffffff",
                anchor: "middle",
                className: "org-label"
            )
        }
        builder.toSvgString()
    }
}

/** 按 id 查找节点。 */
internal func findOrgNode(nodes: ArrayList<OrgNode>, id: String): Option<OrgNode> {
    for (node in nodes) {
        if (node.id == id) {
            return Some(node)
        }
    }
    None<OrgNode>
}

/** 递归设置深度。 */
internal func orgAssignDepth(node: OrgNode): Unit {
    for (child in node.children) {
        child.depth = node.depth + 1
        orgAssignDepth(child)
    }
}

/** 递归分配槽位：叶子依次占槽，父节点取子节点槽位中点。 */
internal func orgAssignSlots(node: OrgNode, cursor: OrgSlotCursor): Unit {
    if (node.children.isEmpty()) {
        node.slot = cursor.next
        cursor.next += 1.0
        return
    }
    for (child in node.children) {
        orgAssignSlots(child, cursor)
    }
    let first = node.children[0].slot
    let last = node.children[node.children.size - 1].slot
    node.slot = (first + last) / 2.0
}

/** 计算组织图节点相对坐标（从 0 开始）。 */
internal func orgLayout(
    nodes: Array<OrgNode>,
    root: OrgNode,
    nodeWidth: Float64,
    nodeHeight: Float64,
    levelGap: Float64,
    horizontal: Bool
): Unit {
    root.depth = 0
    orgAssignDepth(root)
    let cursor = OrgSlotCursor()
    orgAssignSlots(root, cursor)
    let gap = levelGap * 0.5
    for (node in nodes) {
        if (horizontal) {
            node.x = Float64(node.depth) * (nodeWidth + levelGap)
            node.y = node.slot * (nodeHeight + gap)
        } else {
            node.x = node.slot * (nodeWidth + gap)
            node.y = Float64(node.depth) * (nodeHeight + levelGap)
        }
    }
}

/** 按可用宽度截断标签，超出部分以省略号结尾。 */
internal func orgFitLabel(text: String, maxWidth: Float64, fontSize: Float64): String {
    if (chartTextWidth(text, fontSize) <= maxWidth) {
        return text
    }
    let ellipsisWidth = chartTextWidth("…", fontSize)
    var result = ""
    var width = 0.0
    for (rune in text.runes()) {
        let charWidth = if (rune.position() >= 0x2E80) {
            fontSize
        } else {
            fontSize * 0.56
        }
        if (width + charWidth + ellipsisWidth > maxWidth) {
            break
        }
        result += rune.toString()
        width += charWidth
    }
    result + "…"
}
