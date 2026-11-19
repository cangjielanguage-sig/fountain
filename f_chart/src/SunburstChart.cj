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

/** 旭日图节点。 */
internal class SunburstNode {
    let id: String
    let name: String
    let parentId: Option<String>
    let ownValue: Option<Float64>
    let children: ArrayList<SunburstNode>
    var total: Float64
    var depth: Int64
    var startAngle: Float64
    var endAngle: Float64

    init(id: String, name: String, parentId: Option<String>, ownValue: Option<Float64>) {
        this.id = id
        this.name = name
        this.parentId = parentId
        this.ownValue = ownValue
        this.children = ArrayList<SunburstNode>()
        this.total = 0.0
        this.depth = 0
        this.startAngle = 0.0
        this.endAngle = 0.0
    }
}

/** M69 旭日图。 */
public class SunburstChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "sunburst")
        let root = ChartJson.of(data)
        let innerRadius = root.number("innerRadius", default: 0.2)
        if (innerRadius < 0.0 || innerRadius > 0.95) {
            throw chartInvalidValue("innerRadius", "innerRadius 必须在 0–0.95 之间")
        }
        let sort = root.string("sort", default: "value")
        if (sort != "value" && sort != "none") {
            throw chartInvalidValue("sort", "期望 value / none")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<SunburstNode>()
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
            let value = json.number("value")
            nodes.add(SunburstNode(id, json.string("name", default: id), parentId, value))
            nodeIndex++
        }

        let roots = ArrayList<SunburstNode>()
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
        let totalDepth = resolveTotals(rootNode, 0, nodes.size)
        sortChildren(rootNode, sort, nodes.size)
        assignAngles(rootNode, -3.141592653589793 / 2.0, 3.0 * 3.141592653589793 / 2.0)

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let outerRadius = minFloat(frame.plot.width, frame.plot.height) * 0.45
        let innerHole = outerRadius * innerRadius
        let depthCount = if (totalDepth <= 0) { 1 } else { totalDepth }
        let ringWidth = (outerRadius - innerHole) / Float64(depthCount)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        drawNode(kit, config, rootNode, centerX, centerY, innerHole, ringWidth)
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<SunburstNode>, id: String): ?SunburstNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<SunburstNode>
    }

    private func resolveTotals(node: SunburstNode, depth: Int64, total: Int64): Int64 {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        node.depth = depth
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
            return depth
        }
        var sum = 0.0
        var maxDepth = depth
        for (child in node.children) {
            let childDepth = resolveTotals(child, depth + 1, total)
            maxDepth = if (childDepth > maxDepth) { childDepth } else { maxDepth }
            sum += child.total
        }
        node.total = sum
        maxDepth
    }

    private func sortChildren(node: SunburstNode, sort: String, total: Int64): Unit {
        if (node.depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        if (sort == "value" && node.children.size > 1) {
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
            sortChildren(child, sort, total)
        }
    }

    private func assignAngles(node: SunburstNode, start: Float64, end: Float64): Unit {
        node.startAngle = start
        node.endAngle = end
        if (node.children.isEmpty() || node.total <= 0.0) {
            return
        }
        var cursor = start
        for (child in node.children) {
            let span = (end - start) * child.total / node.total
            assignAngles(child, cursor, cursor + span)
            cursor += span
        }
    }

    private func drawNode(
        kit: ChartSvgKit,
        config: ChartConfig,
        node: SunburstNode,
        centerX: Float64,
        centerY: Float64,
        innerHole: Float64,
        ringWidth: Float64
    ): Unit {
        if (node.depth > 0) {
            let inner = innerHole + Float64(node.depth - 1) * ringWidth
            let outer = inner + ringWidth
            let color = config.theme.colorAt(
                flameColorIndex(node.name, config.theme.palette.size)
            )
            kit.path(
                sunburstArcPath(centerX, centerY, inner, outer, node.startAngle, node.endAngle),
                fill: color, stroke: "#ffffff", strokeWidth: 0.8,
                className: "sunburst-arc"
            )
            if (node.depth == 1) {
                let midAngle = (node.startAngle + node.endAngle) / 2.0
                let labelRadius = (inner + outer) / 2.0
                kit.text(
                    centerX + labelRadius * cos(midAngle),
                    centerY + labelRadius * sin(midAngle),
                    node.name,
                    size: config.theme.fontSize - 1.0,
                    color: "#ffffff",
                    anchor: "middle",
                    className: "sunburst-label"
                )
            }
        }
        for (child in node.children) {
            drawNode(kit, config, child, centerX, centerY, innerHole, ringWidth)
        }
    }
}

/** 扇环路径：外弧 + 内弧闭合。 */
internal func sunburstArcPath(
    centerX: Float64,
    centerY: Float64,
    innerRadius: Float64,
    outerRadius: Float64,
    startAngle: Float64,
    endAngle: Float64
): String {
    let largeArc = if (endAngle - startAngle > 3.141592653589793) { 1 } else { 0 }
    let outerStartX = centerX + outerRadius * cos(startAngle)
    let outerStartY = centerY + outerRadius * sin(startAngle)
    let outerEndX = centerX + outerRadius * cos(endAngle)
    let outerEndY = centerY + outerRadius * sin(endAngle)
    let innerEndX = centerX + innerRadius * cos(endAngle)
    let innerEndY = centerY + innerRadius * sin(endAngle)
    let innerStartX = centerX + innerRadius * cos(startAngle)
    let innerStartY = centerY + innerRadius * sin(startAngle)
    "M ${formatSvgNumber(outerStartX)} ${formatSvgNumber(outerStartY)}" +
        " A ${formatSvgNumber(outerRadius)} ${formatSvgNumber(outerRadius)} 0 ${largeArc} 1" +
        " ${formatSvgNumber(outerEndX)} ${formatSvgNumber(outerEndY)}" +
        " L ${formatSvgNumber(innerEndX)} ${formatSvgNumber(innerEndY)}" +
        " A ${formatSvgNumber(innerRadius)} ${formatSvgNumber(innerRadius)} 0 ${largeArc} 0" +
        " ${formatSvgNumber(innerStartX)} ${formatSvgNumber(innerStartY)} Z"
}
