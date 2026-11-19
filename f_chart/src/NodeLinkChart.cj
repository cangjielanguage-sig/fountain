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

/** 节点-链接图节点。 */
internal class NodeLinkNode {
    let id: String
    let name: String
    let group: String
    let manualX: Option<Float64>
    let manualY: Option<Float64>
    var x: Float64
    var y: Float64

    init(id: String, name: String, group: String, manualX: Option<Float64>, manualY: Option<Float64>) {
        this.id = id
        this.name = name
        this.group = group
        this.manualX = manualX
        this.manualY = manualY
        this.x = 0.0
        this.y = 0.0
    }
}

/** 节点-链接图边。 */
internal class NodeLinkEdge {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M62 节点-链接图。 */
public class NodeLinkChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "node-link")
        let root = ChartJson.of(data)
        let layout = root.string("layout", default: "force")
        if (layout != "force" && layout != "circular" && layout != "manual") {
            throw chartInvalidValue("layout", "期望 force / circular / manual")
        }
        let linkDistance = root.number("linkDistance", default: 100.0)
        if (linkDistance <= 0.0) {
            throw chartInvalidValue("linkDistance", "linkDistance 必须大于 0")
        }
        let charge = root.number("charge", default: -300.0)

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<NodeLinkNode>()
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
            let name = json.string("name", default: id)
            let group = json.string("group", default: "")
            let x = json.number("x")
            let y = json.number("y")
            if (layout == "manual") {
                if (x.isNone()) {
                    throw chartMissingField("${itemPath}.x")
                }
                if (y.isNone()) {
                    throw chartMissingField("${itemPath}.y")
                }
            }
            nodes.add(NodeLinkNode(id, name, group, x, y))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let linkItems = linkArray.getItems()
        let edges = ArrayList<NodeLinkEdge>()
        var maxValue = 0.0
        var linkIndex = 0
        for (item in linkItems) {
            let itemPath = "links[${linkIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望链接对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let source = json.requiredString("source")
            let target = json.requiredString("target")
            if (findNode(nodes, source) < 0) {
                throw chartInvalidValue("${itemPath}.source", "节点 ${source} 不存在")
            }
            if (findNode(nodes, target) < 0) {
                throw chartInvalidValue("${itemPath}.target", "节点 ${target} 不存在")
            }
            let value = json.number("value", default: 1.0)
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值必须大于 0")
            }
            maxValue = maxFloat(maxValue, value)
            edges.add(NodeLinkEdge(source, target, value))
            linkIndex++
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        if (layout == "manual") {
            placeManual(nodes)
        } else if (layout == "circular") {
            placeCircular(nodes, frame.plot)
        } else {
            placeCircular(nodes, frame.plot)
            runForce(nodes, edges, frame.plot, linkDistance, abs(charge))
        }

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        for (edge in edges) {
            let source = nodes[findNode(nodes, edge.source)]
            let target = nodes[findNode(nodes, edge.target)]
            kit.line(
                source.x, source.y, target.x, target.y,
                stroke: "#b0b0b0", strokeWidth: nodeLinkWidth(edge.value, maxValue),
                className: "node-link-edge"
            )
        }
        for (node in nodes) {
            let color = if (node.group.isEmpty()) {
                config.theme.colorAt(0)
            } else {
                config.theme.colorAt(flameColorIndex(node.group, config.theme.palette.size))
            }
            kit.circle(node.x, node.y, 8.0, fill: color, className: "node-link-node")
            kit.text(
                node.x, node.y + 18.0, node.name,
                size: config.theme.fontSize - 1.0,
                color: config.theme.textColor,
                anchor: "middle",
                className: "node-link-label"
            )
        }
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<NodeLinkNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }

    private func placeManual(nodes: ArrayList<NodeLinkNode>): Unit {
        for (node in nodes) {
            node.x = match (node.manualX) {
                case Some(value) => value
                case None => 0.0
            }
            node.y = match (node.manualY) {
                case Some(value) => value
                case None => 0.0
            }
        }
    }

    private func placeCircular(nodes: ArrayList<NodeLinkNode>, plot: ChartRect): Unit {
        let centerX = plot.centerX()
        let centerY = plot.centerY()
        let radius = minFloat(plot.width, plot.height) * 0.35
        for (index in 0..nodes.size) {
            let angle = -3.141592653589793 / 2.0 +
                2.0 * 3.141592653589793 * Float64(index) / Float64(nodes.size)
            nodes[index].x = centerX + radius * cos(angle)
            nodes[index].y = centerY + radius * sin(angle)
        }
    }

    private func runForce(
        nodes: ArrayList<NodeLinkNode>,
        edges: ArrayList<NodeLinkEdge>,
        plot: ChartRect,
        linkDistance: Float64,
        charge: Float64
    ): Unit {
        let centerX = plot.centerX()
        let centerY = plot.centerY()
        for (iteration in 0..80) {
            for (left in 0..nodes.size) {
                for (right in left + 1..nodes.size) {
                    let dx = nodes[right].x - nodes[left].x
                    let dy = nodes[right].y - nodes[left].y
                    let distance = sqrt(dx * dx + dy * dy) + 0.01
                    let force = charge / (distance * distance)
                    let fx = dx / distance * force
                    let fy = dy / distance * force
                    nodes[left].x -= fx
                    nodes[left].y -= fy
                    nodes[right].x += fx
                    nodes[right].y += fy
                }
            }
            for (edge in edges) {
                let sourceIndex = findNode(nodes, edge.source)
                let targetIndex = findNode(nodes, edge.target)
                let dx = nodes[targetIndex].x - nodes[sourceIndex].x
                let dy = nodes[targetIndex].y - nodes[sourceIndex].y
                let distance = sqrt(dx * dx + dy * dy) + 0.01
                let force = (distance - linkDistance) * 0.05
                let fx = dx / distance * force
                let fy = dy / distance * force
                nodes[sourceIndex].x += fx
                nodes[sourceIndex].y += fy
                nodes[targetIndex].x -= fx
                nodes[targetIndex].y -= fy
            }
            for (node in nodes) {
                node.x += (centerX - node.x) * 0.01
                node.y += (centerY - node.y) * 0.01
                node.x = clampToPlot(node.x, plot.x, plot.right())
                node.y = clampToPlot(node.y, plot.y, plot.bottom())
            }
        }
    }

    private func clampToPlot(value: Float64, minimum: Float64, maximum: Float64): Float64 {
        if (value < minimum) {
            minimum
        } else if (value > maximum) {
            maximum
        } else {
            value
        }
    }
}

/** 链路值 → 线宽：1px（0）到 4px（最大值）。 */
internal func nodeLinkWidth(value: Float64, maxValue: Float64): Float64 {
    if (value <= 0.0 || maxValue <= 0.0) {
        return 1.0
    }
    let ratio = minFloat(value / maxValue, 1.0)
    1.0 + 3.0 * sqrt(ratio)
}
