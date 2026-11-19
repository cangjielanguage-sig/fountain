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

/** 泳道。 */
internal class SwimLane {
    let id: String
    let name: String

    init(id: String, name: String) {
        this.id = id
        this.name = name
    }
}

/** 泳道节点。 */
internal class SwimNode {
    let id: String
    let label: String
    let laneIndex: Int64
    var x: Float64
    var y: Float64

    init(id: String, label: String, laneIndex: Int64) {
        this.id = id
        this.label = label
        this.laneIndex = laneIndex
        this.x = 0.0
        this.y = 0.0
    }
}

/** 泳道连线。 */
internal class SwimEdge {
    let source: String
    let target: String
    let label: String

    init(source: String, target: String, label: String) {
        this.source = source
        this.target = target
        this.label = label
    }
}

/** M85 泳道图。 */
public class SwimlaneChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "swimlane")
        let root = ChartJson.of(data)
        let direction = root.string("direction", default: "horizontal")
        if (direction != "horizontal" && direction != "vertical") {
            throw chartInvalidValue("direction", "仅支持 horizontal 或 vertical")
        }
        let horizontal = direction == "horizontal"

        let laneArray = root.requiredArray("lanes")
        let laneItems = laneArray.getItems()
        if (laneItems.isEmpty()) {
            throw chartInvalidValue("lanes", "至少需要一个泳道")
        }
        let lanes = ArrayList<SwimLane>()
        var laneIndex = 0
        for (item in laneItems) {
            let itemPath = "lanes[${laneIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望泳道对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let id = json.requiredString("id")
            for (existing in lanes) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "泳道 id 重复")
                }
            }
            lanes.add(SwimLane(id, json.string("name", default: id)))
            laneIndex++
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<SwimNode>()
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
            let laneId = json.requiredString("lane")
            let lanePosition = findSwimLane(lanes, laneId)
            if (lanePosition < 0) {
                throw chartInvalidValue("${itemPath}.lane", "泳道 ${laneId} 不存在")
            }
            nodes.add(SwimNode(id, json.string("label", default: id), lanePosition))
            nodeIndex++
        }

        let edges = ArrayList<SwimEdge>()
        match (root.value("edges")) {
            case Some(entry) =>
                if (!entry.kind.isArray) {
                    throw chartInvalidValue("edges", "期望数组")
                }
                var edgeIndex = 0
                for (item in entry.asArray().getItems()) {
                    let itemPath = "edges[${edgeIndex}]"
                    if (!item.kind.isObject) {
                        throw chartInvalidValue(itemPath, "期望连线对象")
                    }
                    let json = ChartJson.of(item.asObject(), itemPath)
                    let source = json.requiredString("source")
                    let target = json.requiredString("target")
                    if (findSwimNode(nodes, source) < 0) {
                        throw chartInvalidValue("${itemPath}.source", "源节点 ${source} 不存在")
                    }
                    if (findSwimNode(nodes, target) < 0) {
                        throw chartInvalidValue("${itemPath}.target", "目标节点 ${target} 不存在")
                    }
                    edges.add(SwimEdge(source, target, json.string("label", default: "")))
                    edgeIndex++
                }
            case None => ()
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let plot = frame.plot
        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        let nodeWidth = 120.0
        let nodeHeight = 40.0
        let laneLabelWidth = if (horizontal) { 90.0 } else { 30.0 }

        for (index in 0..lanes.size) {
            let lane = lanes[index]
            let fill = if (index % 2 == 0) { "#fafafa" } else { "#f0f0f0" }
            if (horizontal) {
                let height = plot.height / Float64(lanes.size)
                let top = plot.y + Float64(index) * height
                kit.rect(plot.x, top, plot.width, height, fill: fill, className: "swimlane-lane")
                kit.line(
                    plot.x, top, plot.right(), top,
                    stroke: config.theme.axisColor, strokeWidth: 1.0, className: "swimlane-divider"
                )
                kit.text(
                    plot.x + 12.0,
                    top + height / 2.0 + config.theme.fontSize / 3.0,
                    lane.name,
                    size: config.theme.fontSize,
                    color: config.theme.textColor,
                    className: "swimlane-label"
                )
            } else {
                let width = plot.width / Float64(lanes.size)
                let left = plot.x + Float64(index) * width
                kit.rect(left, plot.y, width, plot.height, fill: fill, className: "swimlane-lane")
                kit.line(
                    left, plot.y, left, plot.bottom(),
                    stroke: config.theme.axisColor, strokeWidth: 1.0, className: "swimlane-divider"
                )
                kit.text(
                    left + width / 2.0,
                    plot.y + laneLabelWidth,
                    lane.name,
                    size: config.theme.fontSize,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "swimlane-label"
                )
            }
        }

        let counts = ArrayList<Int64>()
        for (index in 0..lanes.size) {
            counts.add(0)
        }
        for (node in nodes) {
            counts[node.laneIndex] = counts[node.laneIndex] + 1
        }
        let cursors = ArrayList<Int64>()
        for (index in 0..lanes.size) {
            cursors.add(0)
        }
        for (node in nodes) {
            let lane = node.laneIndex
            let position = cursors[lane]
            cursors[lane] = position + 1
            if (horizontal) {
                let laneHeight = plot.height / Float64(lanes.size)
                let contentWidth = plot.width - laneLabelWidth * 2.0
                let slot = contentWidth / Float64(counts[lane] + 1)
                node.x = plot.x + laneLabelWidth + slot * Float64(position + 1) - nodeWidth / 2.0
                node.y = plot.y + Float64(lane) * laneHeight + (laneHeight - nodeHeight) / 2.0
            } else {
                let laneWidth = plot.width / Float64(lanes.size)
                let contentHeight = plot.height - laneLabelWidth * 2.0
                let slot = contentHeight / Float64(counts[lane] + 1)
                node.x = plot.x + Float64(lane) * laneWidth + (laneWidth - nodeWidth) / 2.0
                node.y = plot.y + laneLabelWidth + slot * Float64(position + 1) - nodeHeight / 2.0
            }
        }

        for (edge in edges) {
            let sourceIndex = findSwimNode(nodes, edge.source)
            let targetIndex = findSwimNode(nodes, edge.target)
            let source = nodes[sourceIndex]
            let target = nodes[targetIndex]
            if (horizontal) {
                let startX = source.x + nodeWidth
                let startY = source.y + nodeHeight / 2.0
                let endX = target.x
                let endY = target.y + nodeHeight / 2.0
                let midX = (startX + endX) / 2.0
                kit.path(
                    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                        " H ${formatSvgNumber(midX)} V ${formatSvgNumber(endY)}" +
                        " H ${formatSvgNumber(endX)}",
                    fill: "none",
                    stroke: "#78909c",
                    strokeWidth: 1.5,
                    className: "swimlane-edge"
                )
                kit.path(
                    "M ${formatSvgNumber(endX)} ${formatSvgNumber(endY)}" +
                        " L ${formatSvgNumber(endX - 8.0)} ${formatSvgNumber(endY - 4.0)}" +
                        " L ${formatSvgNumber(endX - 8.0)} ${formatSvgNumber(endY + 4.0)} Z",
                    fill: "#78909c",
                    className: "swimlane-arrow"
                )
                if (!edge.label.isEmpty()) {
                    kit.text(
                        midX + 4.0, endY - 6.0, edge.label,
                        size: config.theme.fontSize - 1.0,
                        color: config.theme.textColor,
                        className: "swimlane-edge-label"
                    )
                }
            } else {
                let startX = source.x + nodeWidth / 2.0
                let startY = source.y + nodeHeight
                let endX = target.x + nodeWidth / 2.0
                let endY = target.y
                let midY = (startY + endY) / 2.0
                kit.path(
                    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                        " V ${formatSvgNumber(midY)} H ${formatSvgNumber(endX)}" +
                        " V ${formatSvgNumber(endY)}",
                    fill: "none",
                    stroke: "#78909c",
                    strokeWidth: 1.5,
                    className: "swimlane-edge"
                )
                kit.path(
                    "M ${formatSvgNumber(endX)} ${formatSvgNumber(endY)}" +
                        " L ${formatSvgNumber(endX - 4.0)} ${formatSvgNumber(endY - 8.0)}" +
                        " L ${formatSvgNumber(endX + 4.0)} ${formatSvgNumber(endY - 8.0)} Z",
                    fill: "#78909c",
                    className: "swimlane-arrow"
                )
                if (!edge.label.isEmpty()) {
                    kit.text(
                        endX + 6.0, midY, edge.label,
                        size: config.theme.fontSize - 1.0,
                        color: config.theme.textColor,
                        className: "swimlane-edge-label"
                    )
                }
            }
        }

        for (node in nodes) {
            let fill = config.theme.colorAt(node.laneIndex)
            kit.rect(
                node.x, node.y, nodeWidth, nodeHeight,
                fill: fill,
                className: "swimlane-node",
                radius: 6.0
            )
            kit.text(
                node.x + nodeWidth / 2.0,
                node.y + nodeHeight / 2.0 + config.theme.fontSize / 3.0,
                orgFitLabel(node.label, nodeWidth - 12.0, config.theme.fontSize),
                size: config.theme.fontSize,
                color: "#ffffff",
                anchor: "middle",
                className: "swimlane-node-label"
            )
        }
        builder.toSvgString()
    }
}

/** 按 id 查泳道索引，未找到返回 −1。 */
internal func findSwimLane(lanes: ArrayList<SwimLane>, id: String): Int64 {
    for (index in 0..lanes.size) {
        if (lanes[index].id == id) {
            return index
        }
    }
    -1
}

/** 按 id 查节点索引，未找到返回 −1。 */
internal func findSwimNode(nodes: ArrayList<SwimNode>, id: String): Int64 {
    for (index in 0..nodes.size) {
        if (nodes[index].id == id) {
            return index
        }
    }
    -1
}
