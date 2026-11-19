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

import std.collection.{ArrayList, HashMap}
import std.math.*
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

internal class FlowNode {
    let id: String
    let label: String
    let shape: String
    let x: ?Float64
    let y: ?Float64
    let width: ?Float64
    let height: ?Float64

    init(
        id: String,
        label: String,
        shape: String,
        x: ?Float64,
        y: ?Float64,
        width: ?Float64,
        height: ?Float64
    ) {
        this.id = id
        this.label = label
        this.shape = shape
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }

    func nodeWidth(): Float64 {
        match (this.width) {
            case Some(value) => value
            case None => if (this.shape == "diamond") { 100.0 } else { 120.0 }
        }
    }

    func nodeHeight(): Float64 {
        match (this.height) {
            case Some(value) => value
            case None => if (this.shape == "diamond") { 70.0 } else { 48.0 }
        }
    }
}

internal class FlowEdge {
    let source: String
    let target: String
    let label: String

    init(source: String, target: String, label: String) {
        this.source = source
        this.target = target
        this.label = label
    }
}

/** M9 流程图：节点、边与分层布局。 */
public class Flowchart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "flowchart")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        if (nodesArray.getItems().isEmpty()) {
            throw chartMissingField("nodes")
        }
        let nodes = parseNodes(nodesArray)
        let edges = parseEdges(root, nodes)

        let idMap = HashMap<String, Int64>()
        for (index in 0..nodes.size) {
            if (idMap.contains(nodes[index].id)) {
                throw chartInvalidValue("nodes[${index}].id", "节点 id 重复")
            }
            idMap[nodes[index].id] = index
        }
        for (index in 0..edges.size) {
            if (!idMap.contains(edges[index].source)) {
                throw chartInvalidValue("edges[${index}].source", "源节点不存在")
            }
            if (!idMap.contains(edges[index].target)) {
                throw chartInvalidValue("edges[${index}].target", "目标节点不存在")
            }
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let layout = root.string("layout", default: "vertical")
        let centersX = Array<Float64>(nodes.size, repeat: 0.0)
        let centersY = Array<Float64>(nodes.size, repeat: 0.0)
        let widths = Array<Float64>(nodes.size, repeat: 0.0)
        let heights = Array<Float64>(nodes.size, repeat: 0.0)
        for (index in 0..nodes.size) {
            widths[index] = nodes[index].nodeWidth()
            heights[index] = nodes[index].nodeHeight()
        }

        if (layout == "manual") {
            for (index in 0..nodes.size) {
                let x = match (nodes[index].x) {
                    case Some(value) => value
                    case None => frame.plot.x
                }
                let y = match (nodes[index].y) {
                    case Some(value) => value
                    case None => frame.plot.y
                }
                centersX[index] = x + widths[index] / 2.0
                centersY[index] = y + heights[index] / 2.0
            }
        } else {
            layoutNodes(nodes, edges, idMap, frame, layout, centersX, centersY, widths, heights)
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
            let sourceIndex = idMap[edge.source]
            let targetIndex = idMap[edge.target]
            drawEdge(kit, config, edge,
                centersX[sourceIndex], centersY[sourceIndex],
                centersX[targetIndex], centersY[targetIndex],
                widths[sourceIndex], heights[sourceIndex],
                widths[targetIndex], heights[targetIndex]
            )
        }
        for (index in 0..nodes.size) {
            drawNode(kit, config, nodes[index],
                centersX[index], centersY[index], widths[index], heights[index]
            )
        }
        builder.toSvgString()
    }

    private func parseNodes(items: JsonArray): Array<FlowNode> {
        let nodes = ArrayList<FlowNode>()
        var index = 0
        for (item in items.getItems()) {
            let path = "nodes[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let id = json.requiredString("id")
            let label = json.string("label", default: id)
            let shape = json.string("shape", default: "rect")
            nodes.add(FlowNode(
                id, label, shape,
                json.number("x"), json.number("y"),
                json.number("width"), json.number("height")
            ))
            index++
        }
        nodes.toArray()
    }

    private func parseEdges(root: ChartJson, nodes: Array<FlowNode>): Array<FlowEdge> {
        let edges = ArrayList<FlowEdge>()
        match (root.array("edges")) {
            case Some(items) =>
                var index = 0
                for (item in items.getItems()) {
                    let path = "edges[${index}]"
                    if (!item.kind.isObject) {
                        throw chartInvalidValue(path, "期望对象")
                    }
                    let json = ChartJson.of(item.asObject(), path)
                    edges.add(FlowEdge(
                        json.requiredString("source"),
                        json.requiredString("target"),
                        json.string("label", default: "")
                    ))
                    index++
                }
            case None => ()
        }
        edges.toArray()
    }

    private func layoutNodes(
        nodes: Array<FlowNode>,
        edges: Array<FlowEdge>,
        idMap: HashMap<String, Int64>,
        frame: ChartFrame,
        layout: String,
        centersX: Array<Float64>,
        centersY: Array<Float64>,
        widths: Array<Float64>,
        heights: Array<Float64>
    ): Unit {
        let levels = Array<Int64>(nodes.size, repeat: 0)
        for (_ in 0..nodes.size) {
            for (edge in edges) {
                let source = idMap[edge.source]
                let target = idMap[edge.target]
                if (levels[source] + 1 > levels[target]) {
                    levels[target] = levels[source] + 1
                }
            }
        }
        var maxLevel = 0
        for (level in levels) {
            maxLevel = maxInt64(maxLevel, level)
        }
        let counts = Array<Int64>(maxLevel + 1, repeat: 0)
        for (level in levels) {
            counts[level]++
        }
        let ranks = Array<Int64>(maxLevel + 1, repeat: 0)
        var maxNodeWidth = 0.0
        var maxNodeHeight = 0.0
        for (index in 0..nodes.size) {
            if (widths[index] > maxNodeWidth) {
                maxNodeWidth = widths[index]
            }
            if (heights[index] > maxNodeHeight) {
                maxNodeHeight = heights[index]
            }
        }
        for (index in 0..nodes.size) {
            let level = levels[index]
            let rank = ranks[level]
            ranks[level] = rank + 1
            if (layout == "horizontal") {
                centersX[index] = frame.plot.x + Float64(level) * (maxNodeWidth + 90.0) + widths[index] / 2.0
                let slot = frame.plot.height / Float64(counts[level] + 1)
                centersY[index] = frame.plot.y + slot * Float64(rank + 1)
            } else {
                centersY[index] = frame.plot.y + Float64(level) * (maxNodeHeight + 90.0) + heights[index] / 2.0
                let slot = frame.plot.width / Float64(counts[level] + 1)
                centersX[index] = frame.plot.x + slot * Float64(rank + 1)
            }
        }
    }

    private func drawEdge(
        kit: ChartSvgKit,
        config: ChartConfig,
        edge: FlowEdge,
        sx: Float64,
        sy: Float64,
        tx: Float64,
        ty: Float64,
        sourceWidth: Float64,
        sourceHeight: Float64,
        targetWidth: Float64,
        targetHeight: Float64
    ): Unit {
        let dx = tx - sx
        let dy = ty - sy
        let length = sqrt(dx * dx + dy * dy)
        if (length < 1e-9) {
            return
        }
        let ux = dx / length
        let uy = dy / length
        let startOffset = minFloat(sourceWidth, sourceHeight) / 2.0 + 2.0
        let endOffset = minFloat(targetWidth, targetHeight) / 2.0 + 2.0
        let x1 = sx + ux * startOffset
        let y1 = sy + uy * startOffset
        let x2 = tx - ux * endOffset
        let y2 = ty - uy * endOffset
        kit.line(x1, y1, x2, y2, stroke: config.theme.axisColor, strokeWidth: 1.2, className: "edge")
        let arrow = "M ${formatSvgNumber(x2)} ${formatSvgNumber(y2)} " +
            "L ${formatSvgNumber(x2 - ux * 9.0 - uy * 4.0)} ${formatSvgNumber(y2 - uy * 9.0 + ux * 4.0)} " +
            "L ${formatSvgNumber(x2 - ux * 9.0 + uy * 4.0)} ${formatSvgNumber(y2 - uy * 9.0 - ux * 4.0)} Z"
        kit.path(arrow, fill: config.theme.axisColor, className: "edge-arrow")
        if (!edge.label.isEmpty()) {
            kit.text(
                (x1 + x2) / 2.0, (y1 + y2) / 2.0 - 6.0, edge.label,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "edge-label"
            )
        }
    }

    private func drawNode(
        kit: ChartSvgKit,
        config: ChartConfig,
        node: FlowNode,
        cx: Float64,
        cy: Float64,
        width: Float64,
        height: Float64
    ): Unit {
        let fill = if (config.theme.background == "none") { "#ffffff" } else { config.theme.background }
        let stroke = config.theme.axisColor
        let x = cx - width / 2.0
        let y = cy - height / 2.0
        match (node.shape) {
            case "diamond" =>
                let d = "M ${formatSvgNumber(cx)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(x + width)} ${formatSvgNumber(cy)} " +
                    "L ${formatSvgNumber(cx)} ${formatSvgNumber(y + height)} " +
                    "L ${formatSvgNumber(x)} ${formatSvgNumber(cy)} Z"
                kit.path(d, fill: fill, stroke: stroke, className: "node node-diamond")
            case "ellipse" =>
                kit.ellipse(cx, cy, width / 2.0, height / 2.0, fill: fill, stroke: stroke, className: "node")
            case "round" =>
                kit.rect(x, y, width, height, fill: fill, stroke: stroke, className: "node", radius: Some(height / 2.0))
            case "parallelogram" =>
                let offset = 14.0
                let d = "M ${formatSvgNumber(x + offset)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(x + width)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(x + width - offset)} ${formatSvgNumber(y + height)} " +
                    "L ${formatSvgNumber(x)} ${formatSvgNumber(y + height)} Z"
                kit.path(d, fill: fill, stroke: stroke, className: "node")
            case "document" =>
                let d = "M ${formatSvgNumber(x)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(x + width)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(x + width)} ${formatSvgNumber(y + height - 8.0)} " +
                    "Q ${formatSvgNumber(x + width / 2.0)} ${formatSvgNumber(y + height + 4.0)} " +
                    "${formatSvgNumber(x)} ${formatSvgNumber(y + height - 8.0)} Z"
                kit.path(d, fill: fill, stroke: stroke, className: "node")
            case _ =>
                kit.rect(x, y, width, height, fill: fill, stroke: stroke, className: "node")
        }
        kit.text(
            cx, cy, node.label,
            size: config.theme.fontSize,
            color: config.theme.textColor,
            anchor: "middle",
            className: "node-label"
        )
    }
}
