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
package fountain::f_chart.tui

import std.collection.ArrayList
import std.math.*
import fountain::f_chart.*
import fountain::f_data.json.*

/** 火焰图节点在字符画布上的列范围与深度。 */
internal class TuiFlameBox {
    let node: FlameNode
    let start: Int64
    let end: Int64
    let depth: Int64

    init(node: FlameNode, start: Int64, end: Int64, depth: Int64) {
        this.node = node
        this.start = start
        this.end = end
        this.depth = depth
    }
}

/** M52 火焰图的 TUI 实现。 */
public class TuiFlameChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(
            data, "flame", defaultWidth: 80.0, defaultHeight: 24.0
        )
        let root = ChartJson.of(data)
        let nodes = parseNodes(root.requiredArray("nodes"))
        let rootNode = resolveRoot(nodes)
        validateTree(rootNode, 0, nodes.size)
        assignDepth(rootNode, 0, nodes.size)

        let orientation = root.string("orientation", default: "bottom-up")
        if (orientation != "bottom-up" && orientation != "top-down") {
            throw chartInvalidValue("orientation", "期望 bottom-up / top-down")
        }
        let colorBy = root.string("colorBy", default: "name")
        if (colorBy != "name" && colorBy != "value") {
            throw chartInvalidValue("colorBy", "期望 name / value")
        }
        let configuredHeight = root.number("frameHeight", default: 18.0)
        if (configuredHeight <= 0.0) {
            throw chartInvalidValue("frameHeight", "层高必须大于 0")
        }

        var maxDepth = rootNode.depth
        for (node in nodes) {
            if (node.depth > maxDepth) {
                maxDepth = node.depth
            }
        }

        let frame = TuiFrame(config, 0)
        let canvas = TuiCanvas(Int64(config.width), Int64(config.height))
        frame.drawTitle(canvas)
        let fitRows = Int64(floor(
            Float64(frame.plot.height) / Float64(maxDepth + 1)
        ))
        if (fitRows < 1) {
            throw chartInvalidValue("height", "绘图区高度不足以容纳所有层级")
        }
        let configuredRows = Int64(floor(configuredHeight))
        let rowsPerDepth = if (configuredRows > 0 && configuredRows < fitRows) {
            configuredRows
        } else {
            fitRows
        }

        let boxes = ArrayList<TuiFlameBox>()
        layoutNode(rootNode, frame.plot.x, frame.plot.right() + 1, 0, boxes)
        for (box in boxes) {
            drawBox(
                canvas, frame, box, rootNode.value, rowsPerDepth,
                orientation, colorBy, config
            )
        }
        canvas.render()
    }

    private func parseNodes(array: JsonArray): ArrayList<FlameNode> {
        let items = array.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let nodes = ArrayList<FlameNode>()
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
            for (existing in nodes) {
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
            nodes.add(FlameNode(id, name, parentId, value))
            index++
        }
        nodes
    }

    private func findNode(nodes: ArrayList<FlameNode>, id: String): ?FlameNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<FlameNode>
    }

    private func resolveRoot(nodes: ArrayList<FlameNode>): FlameNode {
        let roots = ArrayList<FlameNode>()
        for (node in nodes) {
            match (node.parentId) {
                case Some(parentId) =>
                    match (findNode(nodes, parentId)) {
                        case Some(parent) => parent.children.add(node)
                        case None =>
                            throw chartInvalidValue("nodes", "父节点 ${parentId} 不存在")
                    }
                case None => roots.add(node)
            }
        }
        if (roots.size != 1) {
            throw chartInvalidValue("nodes", "必须恰好有一个根节点")
        }
        roots[0]
    }

    private func validateTree(node: FlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        var childTotal = 0.0
        for (child in node.children) {
            childTotal += child.value
        }
        if (node.children.size > 0 && childTotal > node.value + 1e-6) {
            throw chartInvalidValue(
                "nodes", "节点 ${node.id} 的值小于子节点之和"
            )
        }
        for (child in node.children) {
            validateTree(child, depth + 1, total)
        }
    }

    private func assignDepth(node: FlameNode, depth: Int64, total: Int64): Unit {
        if (depth > total) {
            throw chartInvalidValue("nodes", "节点关系存在环")
        }
        node.depth = depth
        for (child in node.children) {
            assignDepth(child, depth + 1, total)
        }
    }

    private func layoutNode(
        node: FlameNode,
        start: Int64,
        end: Int64,
        depth: Int64,
        boxes: ArrayList<TuiFlameBox>
    ): Unit {
        boxes.add(TuiFlameBox(node, start, end, depth))
        if (node.children.isEmpty() || end <= start) {
            return
        }
        let span = Float64(end - start)
        var accumulated = 0.0
        for (child in node.children) {
            let childStart = Int64(round(
                Float64(start) + accumulated / node.value * span
            ))
            accumulated += child.value
            let childEnd = Int64(round(
                Float64(start) + accumulated / node.value * span
            ))
            if (childEnd > childStart) {
                layoutNode(child, childStart, childEnd, depth + 1, boxes)
            }
        }
    }

    private func drawBox(
        canvas: TuiCanvas,
        frame: TuiFrame,
        box: TuiFlameBox,
        rootValue: Float64,
        rowsPerDepth: Int64,
        orientation: String,
        colorBy: String,
        config: ChartConfig
    ): Unit {
        let ratio = box.node.value / rootValue
        let color = if (colorBy == "value") {
            heatColor(ratio)
        } else {
            config.theme.colorAt(flameColorIndex(
                box.node.name, config.theme.palette.size
            ))
        }
        let top = if (orientation == "bottom-up") {
            frame.plot.bottom() - (box.depth + 1) * rowsPerDepth + 1
        } else {
            frame.plot.y + box.depth * rowsPerDepth
        }
        let bottom = tuiMinInt64(top + rowsPerDepth - 1, frame.plot.bottom())
        let left = tuiMaxInt64(box.start, frame.plot.x)
        let right = tuiMinInt64(box.end, frame.plot.right() + 1)
        if (right <= left || bottom < top) {
            return
        }
        for (row in top..bottom + 1) {
            for (column in left..right) {
                canvas.set(column, row, "█", color)
            }
        }
        let width = right - left
        if (width >= tuiDisplayWidth(box.node.name) + 2) {
            let labelRow = top + (bottom - top) / 2
            canvas.putText(
                left + 1, labelRow, box.node.name, tuiContrastColor(color),
                maxWidth: width - 1
            )
        }
    }
}
