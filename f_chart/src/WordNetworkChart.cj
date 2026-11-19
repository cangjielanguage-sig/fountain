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

internal class WordNetworkNode {
    let id: String
    let name: String
    let weight: Float64
    var x: Float64
    var y: Float64

    init(id: String, name: String, weight: Float64) {
        this.id = id
        this.name = name
        this.weight = weight
        this.x = 0.0
        this.y = 0.0
    }
}

internal class WordNetworkLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M103 词网络图。 */
public class WordNetworkChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "word-network")
        let root = ChartJson.of(data)
        let layout = root.string("layout", default: "force")
        if (layout != "force" && layout != "circular") {
            throw chartInvalidValue("layout", "期望 force / circular")
        }
        let linkDistance = root.number("linkDistance", default: 100.0)
        if (linkDistance <= 0.0) {
            throw chartInvalidValue("linkDistance", "linkDistance 必须大于 0")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<WordNetworkNode>()
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
            let weight = json.number("weight", default: 1.0)
            if (weight <= 0.0) {
                throw chartInvalidValue("${itemPath}.weight", "权重必须大于 0")
            }
            nodes.add(WordNetworkNode(id, name, weight))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let links = ArrayList<WordNetworkLink>()
        var maxValue = 0.0
        var linkIndex = 0
        for (item in linkArray.getItems()) {
            let itemPath = "links[${linkIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望链接对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let source = json.requiredString("source")
            let target = json.requiredString("target")
            if (findWordNode(nodes, source) < 0) {
                throw chartInvalidValue("${itemPath}.source", "节点 ${source} 不存在")
            }
            if (findWordNode(nodes, target) < 0) {
                throw chartInvalidValue("${itemPath}.target", "节点 ${target} 不存在")
            }
            let value = json.number("value", default: 1.0)
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值必须大于 0")
            }
            maxValue = maxFloat(maxValue, value)
            links.add(WordNetworkLink(source, target, value))
            linkIndex++
        }

        var maxWeight = nodes[0].weight
        for (node in nodes) {
            maxWeight = maxFloat(maxWeight, node.weight)
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        placeWordRing(nodes, frame.plot)
        if (layout == "force") {
            runWordForce(nodes, links, frame.plot, linkDistance)
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
            let source = nodes[findWordNode(nodes, link.source)]
            let target = nodes[findWordNode(nodes, link.target)]
            kit.line(
                source.x, source.y, target.x, target.y,
                stroke: "#b0b0b0",
                strokeWidth: nodeLinkWidth(link.value, maxValue),
                className: "word-network-link"
            )
        }
        for (node in nodes) {
            let radius = wordNetworkRadius(node.weight, maxWeight)
            let color = config.theme.colorAt(
                flameColorIndex(node.name, config.theme.palette.size)
            )
            kit.circle(node.x, node.y, radius, fill: color, className: "word-network-node")
            let fontSize = 10.0 + (radius - 8.0) / 10.0 * 5.0
            kit.text(
                node.x, node.y, node.name,
                size: fontSize,
                color: "#ffffff",
                anchor: "middle",
                className: "word-network-label"
            )
        }
        builder.toSvgString()
    }

    private func findWordNode(nodes: ArrayList<WordNetworkNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }

    private func placeWordRing(nodes: ArrayList<WordNetworkNode>, plot: ChartRect): Unit {
        let centerX = plot.centerX()
        let centerY = plot.centerY()
        let radius = minFloat(plot.width, plot.height) * 0.35
        for (index in 0..nodes.size) {
            let point = wordNetworkRingPoint(centerX, centerY, radius, index, nodes.size)
            nodes[index].x = point[0]
            nodes[index].y = point[1]
        }
    }

    private func runWordForce(
        nodes: ArrayList<WordNetworkNode>,
        links: ArrayList<WordNetworkLink>,
        plot: ChartRect,
        linkDistance: Float64
    ): Unit {
        let centerX = plot.centerX()
        let centerY = plot.centerY()
        for (iteration in 0..80) {
            for (left in 0..nodes.size) {
                for (right in left + 1..nodes.size) {
                    let dx = nodes[right].x - nodes[left].x
                    let dy = nodes[right].y - nodes[left].y
                    let distance = sqrt(dx * dx + dy * dy) + 0.01
                    let force = -300.0 / (distance * distance)
                    let fx = dx / distance * force
                    let fy = dy / distance * force
                    nodes[left].x -= fx
                    nodes[left].y -= fy
                    nodes[right].x += fx
                    nodes[right].y += fy
                }
            }
            for (link in links) {
                let sourceIndex = findWordNode(nodes, link.source)
                let targetIndex = findWordNode(nodes, link.target)
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
                node.x = clampWordCoordinate(node.x, plot.x + 20.0, plot.right() - 20.0)
                node.y = clampWordCoordinate(node.y, plot.y + 20.0, plot.bottom() - 20.0)
            }
        }
    }

    private func clampWordCoordinate(value: Float64, minimum: Float64, maximum: Float64): Float64 {
        if (value < minimum) {
            minimum
        } else if (value > maximum) {
            maximum
        } else {
            value
        }
    }
}

/** 权重 → 节点半径：[8, 18] 的开方映射。 */
internal func wordNetworkRadius(weight: Float64, maxWeight: Float64): Float64 {
    if (weight <= 0.0 || maxWeight <= 0.0) {
        return 8.0
    }
    let ratio = minFloat(weight / maxWeight, 1.0)
    8.0 + 10.0 * sqrt(ratio)
}

/** 圆周上第 index 个点，从正上方开始顺时针分布。 */
internal func wordNetworkRingPoint(
    centerX: Float64,
    centerY: Float64,
    radius: Float64,
    index: Int64,
    count: Int64
): Array<Float64> {
    if (count <= 0) {
        return [centerX, centerY]
    }
    let angle = -3.141592653589793 / 2.0 +
        2.0 * 3.141592653589793 * Float64(index) / Float64(count)
    [centerX + radius * cos(angle), centerY + radius * sin(angle)]
}
