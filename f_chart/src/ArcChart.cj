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

/** 弧线图节点。 */
internal class ArcNode {
    let id: String
    let name: String
    var x: Float64
    var y: Float64
    var angle: Float64

    init(id: String, name: String) {
        this.id = id
        this.name = name
        this.x = 0.0
        this.y = 0.0
        this.angle = 0.0
    }
}

/** 弧线图链接。 */
internal class ArcLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M63 弧线图。 */
public class ArcChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "arc")
        let root = ChartJson.of(data)
        let arcHeight = root.number("arcHeight", default: 0.5)
        if (arcHeight < 0.0 || arcHeight > 1.0) {
            throw chartInvalidValue("arcHeight", "arcHeight 必须在 0–1 之间")
        }
        let sort = root.string("sort", default: "none")
        if (sort != "value" && sort != "none") {
            throw chartInvalidValue("sort", "期望 value / none")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.size < 2) {
            throw chartInvalidValue("nodes", "至少需要两个节点")
        }
        let nodes = ArrayList<ArcNode>()
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
            nodes.add(ArcNode(id, json.string("name", default: id)))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let linkItems = linkArray.getItems()
        if (linkItems.isEmpty()) {
            throw chartInvalidValue("links", "至少需要一条链接")
        }
        let links = ArrayList<ArcLink>()
        var totals = Array<Float64>(nodes.size, repeat: 0.0)
        var linkIndex = 0
        for (item in linkItems) {
            let itemPath = "links[${linkIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望链接对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let source = json.requiredString("source")
            let target = json.requiredString("target")
            let sourceIndex = findNode(nodes, source)
            let targetIndex = findNode(nodes, target)
            if (sourceIndex < 0) {
                throw chartInvalidValue("${itemPath}.source", "节点 ${source} 不存在")
            }
            if (targetIndex < 0) {
                throw chartInvalidValue("${itemPath}.target", "节点 ${target} 不存在")
            }
            let value = json.number("value", default: 1.0)
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值必须大于 0")
            }
            totals[sourceIndex] += value
            totals[targetIndex] += value
            links.add(ArcLink(source, target, value))
            linkIndex++
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let radius = minFloat(frame.plot.width, frame.plot.height) * 0.35
        let order = if (sort == "value") {
            arcNodeOrder(totals)
        } else {
            sequentialOrder(nodes.size)
        }
        for (rank in 0..order.size) {
            let node = nodes[order[rank]]
            let angle = -3.141592653589793 / 2.0 +
                2.0 * 3.141592653589793 * Float64(rank) / Float64(nodes.size)
            node.angle = angle
            node.x = centerX + radius * cos(angle)
            node.y = centerY + radius * sin(angle)
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

        for (link in links) {
            let source = nodes[findNode(nodes, link.source)]
            let target = nodes[findNode(nodes, link.target)]
            let midX = (source.x + target.x) / 2.0
            let midY = (source.y + target.y) / 2.0
            let controlX = midX + (centerX - midX) * arcHeight
            let controlY = midY + (centerY - midY) * arcHeight
            let path = "M ${formatSvgNumber(source.x)} ${formatSvgNumber(source.y)}" +
                " Q ${formatSvgNumber(controlX)} ${formatSvgNumber(controlY)}" +
                " ${formatSvgNumber(target.x)} ${formatSvgNumber(target.y)}"
            kit.path(
                path, fill: "none", stroke: config.theme.colorAt(0), strokeWidth: 1.5,
                className: "arc-line"
            )
        }
        for (index in 0..nodes.size) {
            let node = nodes[index]
            kit.circle(
                node.x, node.y, 6.0,
                fill: config.theme.colorAt(index), className: "arc-node"
            )
            let labelRadius = radius + 14.0
            let labelX = centerX + labelRadius * cos(node.angle)
            let labelY = centerY + labelRadius * sin(node.angle)
            let anchor = if (cos(node.angle) > 0.2) {
                "start"
            } else if (cos(node.angle) < -0.2) {
                "end"
            } else {
                "middle"
            }
            kit.text(
                labelX, labelY, node.name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: anchor,
                className: "arc-label"
            )
        }
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<ArcNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }

    private func sequentialOrder(count: Int64): Array<Int64> {
        let order = ArrayList<Int64>()
        for (index in 0..count) {
            order.add(index)
        }
        order.toArray()
    }
}

/** 按关联总流量降序返回节点下标（稳定排序）。 */
internal func arcNodeOrder(totals: Array<Float64>): Array<Int64> {
    let order = ArrayList<Int64>()
    for (index in 0..totals.size) {
        order.add(index)
    }
    for (i in 1..order.size) {
        var j = i
        while (j > 0 && totals[order[j]] > totals[order[j - 1]]) {
            let temporary = order[j]
            order[j] = order[j - 1]
            order[j - 1] = temporary
            j--
        }
    }
    order.toArray()
}
