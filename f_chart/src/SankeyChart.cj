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

/** 桑基图节点。 */
internal class SankeyNode {
    let id: String
    let name: String
    var layer: Int64 = 0
    var throughput: Float64 = 0.0
    var x: Float64 = 0.0
    var y: Float64 = 0.0
    var height: Float64 = 0.0

    init(id: String, name: String) {
        this.id = id
        this.name = name
    }
}

/** 桑基图链接。 */
internal class SankeyLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/**
 * M36 桑基图。
 *
 * 节点按最长路径分层，链接以带宽展示流量大小。
 */
public class SankeyChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "sankey")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        let nodeItems = nodesArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let nodes = ArrayList<SankeyNode>()
        var nodeIndex = 0
        for (item in nodeItems) {
            let itemPath = "nodes[${nodeIndex}]"
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
            nodes.add(SankeyNode(id, json.string("name", default: id)))
            nodeIndex++
        }

        let linksArray = root.requiredArray("links")
        let links = ArrayList<SankeyLink>()
        var linkIndex = 0
        for (item in linksArray.getItems()) {
            let itemPath = "links[${linkIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望链接对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let source = json.string("source", default: "")
            let target = json.string("target", default: "")
            if (indexOfNode(nodes, source) < 0 || indexOfNode(nodes, target) < 0) {
                throw chartInvalidValue(itemPath, "链接端点不存在")
            }
            let valueJson = json.required("value")
            if (!(valueJson.kind.isInt || valueJson.kind.isDecimal)) {
                throw chartInvalidValue("${itemPath}.value", "期望数字")
            }
            let value = jsonNumberValue(valueJson, "${itemPath}.value")
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "流量必须大于 0")
            }
            links.add(SankeyLink(source, target, value))
            linkIndex++
        }

        let sources = ArrayList<Int64>()
        let targets = ArrayList<Int64>()
        for (link in links) {
            sources.add(indexOfNode(nodes, link.source))
            targets.add(indexOfNode(nodes, link.target))
        }
        let layers = sankeyLayers(nodes.size, sources.toArray(), targets.toArray())
        var maxLayer = 0
        for (layer in layers) {
            if (layer > maxLayer) {
                maxLayer = layer
            }
        }

        let incoming = ArrayList<Float64>()
        let outgoing = ArrayList<Float64>()
        for (_ in 0..nodes.size) {
            incoming.add(0.0)
            outgoing.add(0.0)
        }
        var maxFlow = 0.0
        for (link in links) {
            let sourceIndex = indexOfNode(nodes, link.source)
            let targetIndex = indexOfNode(nodes, link.target)
            outgoing[sourceIndex] = outgoing[sourceIndex] + link.value
            incoming[targetIndex] = incoming[targetIndex] + link.value
            if (link.value > maxFlow) {
                maxFlow = link.value
            }
        }
        var maxThroughput = 0.0
        for (index in 0..nodes.size) {
            nodes[index].layer = layers[index]
            let throughput = maxFloat(incoming[index], outgoing[index])
            nodes[index].throughput = throughput
            if (throughput > maxThroughput) {
                maxThroughput = throughput
            }
        }
        if (maxThroughput <= 0.0) {
            maxThroughput = 1.0
        }

        let nodeWidth = root.number("nodeWidth", default: 16.0)
        let nodeGap = root.number("nodeGap", default: 12.0)
        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        if (!config.title.isEmpty()) {
            kit.text(
                config.width / 2.0, config.padding.top + config.titleFontSize,
                config.title,
                size: config.titleFontSize,
                color: config.titleColor,
                anchor: "middle",
                className: "title"
            )
        }

        let left = config.padding.left + 30.0
        let right = config.width - config.padding.right - 30.0
        let top = config.padding.top + 70.0
        let bottom = config.height - config.padding.bottom - 30.0
        let plotHeight = bottom - top
        let maxNodeHeight = plotHeight * 0.9
        for (layer in 0..=maxLayer) {
            let members = ArrayList<Int64>()
            for (index in 0..nodes.size) {
                if (nodes[index].layer == layer) {
                    members.add(index)
                }
            }
            let gapCount = if (members.size > 1) { members.size - 1 } else { 0 }
            var totalHeight = nodeGap * Float64(gapCount)
            for (index in members) {
                totalHeight += maxFloat(
                    nodes[index].throughput / maxThroughput * maxNodeHeight, 6.0
                )
            }
            var y = top + (plotHeight - totalHeight) / 2.0
            let x = if (maxLayer == 0) {
                (left + right) / 2.0
            } else {
                left + Float64(layer) / Float64(maxLayer) * (right - left - nodeWidth)
            }
            for (index in members) {
                let height = maxFloat(
                    nodes[index].throughput / maxThroughput * maxNodeHeight, 6.0
                )
                nodes[index].x = x
                nodes[index].y = y
                nodes[index].height = height
                y += height + nodeGap
            }
        }

        let outOffsets = ArrayList<Float64>()
        let inOffsets = ArrayList<Float64>()
        for (_ in 0..nodes.size) {
            outOffsets.add(0.0)
            inOffsets.add(0.0)
        }
        for (link in links) {
            let sourceIndex = indexOfNode(nodes, link.source)
            let targetIndex = indexOfNode(nodes, link.target)
            let strokeWidth = maxFloat(link.value / maxFlow * 22.0, 1.0)
            let sourceNode = nodes[sourceIndex]
            let targetNode = nodes[targetIndex]
            let startX = sourceNode.x + nodeWidth
            let startY = sourceNode.y + outOffsets[sourceIndex] + strokeWidth / 2.0
            let endX = targetNode.x
            let endY = targetNode.y + inOffsets[targetIndex] + strokeWidth / 2.0
            outOffsets[sourceIndex] = outOffsets[sourceIndex] + strokeWidth + 1.0
            inOffsets[targetIndex] = inOffsets[targetIndex] + strokeWidth + 1.0
            let middleX = (startX + endX) / 2.0
            let path = "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
                " C ${formatSvgNumber(middleX)} ${formatSvgNumber(startY)}" +
                " ${formatSvgNumber(middleX)} ${formatSvgNumber(endY)}" +
                " ${formatSvgNumber(endX)} ${formatSvgNumber(endY)}"
            kit.path(
                path, fill: "none", stroke: config.theme.colorAt(sourceIndex),
                strokeWidth: strokeWidth, className: "sankey-link"
            )
        }
        for (index in 0..nodes.size) {
            let node = nodes[index]
            kit.rect(
                node.x, node.y, nodeWidth, node.height,
                fill: config.theme.colorAt(index), className: "sankey-node"
            )
            kit.text(
                if (node.layer == maxLayer) { node.x - 6.0 } else { node.x + nodeWidth + 6.0 },
                node.y + node.height / 2.0 + config.theme.fontSize / 3.0,
                node.name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: if (node.layer == maxLayer) { "end" } else { "start" },
                className: "sankey-label"
            )
        }
        builder.toSvgString()
    }

    private func indexOfNode(nodes: ArrayList<SankeyNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }
}

/** 最长路径层级；循环依赖在 nodeCount 轮后稳定。 */
internal func sankeyLayers(
    nodeCount: Int64,
    sources: Array<Int64>,
    targets: Array<Int64>
): Array<Int64> {
    let layers = ArrayList<Int64>()
    for (_ in 0..nodeCount) {
        layers.add(0)
    }
    for (_ in 0..nodeCount) {
        var changed = false
        for (index in 0..sources.size) {
            let candidate = layers[sources[index]] + 1
            if (candidate > layers[targets[index]]) {
                layers[targets[index]] = candidate
                changed = true
            }
        }
        if (!changed) {
            break
        }
    }
    layers.toArray()
}
