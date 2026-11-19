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

/** 和弦图节点。 */
internal class ChordNode {
    let id: String
    let name: String
    var total: Float64
    var startAngle: Float64
    var endAngle: Float64
    var midAngle: Float64

    init(id: String, name: String) {
        this.id = id
        this.name = name
        this.total = 0.0
        this.startAngle = 0.0
        this.endAngle = 0.0
        this.midAngle = 0.0
    }
}

/** 和弦图链接。 */
internal class ChordLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M64 和弦图。 */
public class ChordChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "chord")
        let root = ChartJson.of(data)
        let padAngle = root.number("padAngle", default: 0.02)
        if (padAngle < 0.0) {
            throw chartInvalidValue("padAngle", "padAngle 不能为负")
        }
        let showLabels = root.bool("showLabels", default: false)

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.size < 2) {
            throw chartInvalidValue("nodes", "至少需要两个节点")
        }
        let nodes = ArrayList<ChordNode>()
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
            nodes.add(ChordNode(id, json.string("name", default: id)))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let linkItems = linkArray.getItems()
        if (linkItems.isEmpty()) {
            throw chartInvalidValue("links", "至少需要一条链接")
        }
        let links = ArrayList<ChordLink>()
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
            let sourceIndex = findNode(nodes, source)
            let targetIndex = findNode(nodes, target)
            if (sourceIndex < 0) {
                throw chartInvalidValue("${itemPath}.source", "节点 ${source} 不存在")
            }
            if (targetIndex < 0) {
                throw chartInvalidValue("${itemPath}.target", "节点 ${target} 不存在")
            }
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值必须大于 0")
            }
            nodes[sourceIndex].total += value
            nodes[targetIndex].total += value
            maxValue = maxFloat(maxValue, value)
            links.add(ChordLink(source, target, value))
            linkIndex++
        }

        var total = 0.0
        for (node in nodes) {
            total += node.total
        }
        if (total <= 0.0) {
            throw chartInvalidValue("links", "总流量必须大于 0")
        }
        if (padAngle * Float64(nodes.size) >= 2.0 * 3.141592653589793) {
            throw chartInvalidValue("padAngle", "分段间隔过大")
        }
        let available = 2.0 * 3.141592653589793 - padAngle * Float64(nodes.size)
        var cursor = -3.141592653589793 / 2.0
        for (node in nodes) {
            let span = node.total / total * available
            node.startAngle = cursor + padAngle / 2.0
            node.endAngle = node.startAngle + span
            node.midAngle = (node.startAngle + node.endAngle) / 2.0
            cursor = node.endAngle + padAngle / 2.0
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let radius = minFloat(frame.plot.width, frame.plot.height) * 0.35

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        for (index in 0..nodes.size) {
            let node = nodes[index]
            kit.path(
                chordArcPath(centerX, centerY, radius, node.startAngle, node.endAngle),
                fill: "none", stroke: config.theme.colorAt(index), strokeWidth: 14.0,
                className: "chord-arc"
            )
        }
        for (link in links) {
            let source = nodes[findNode(nodes, link.source)]
            let target = nodes[findNode(nodes, link.target)]
            let sourceX = centerX + radius * cos(source.midAngle)
            let sourceY = centerY + radius * sin(source.midAngle)
            let targetX = centerX + radius * cos(target.midAngle)
            let targetY = centerY + radius * sin(target.midAngle)
            let path = "M ${formatSvgNumber(sourceX)} ${formatSvgNumber(sourceY)}" +
                " Q ${formatSvgNumber(centerX)} ${formatSvgNumber(centerY)}" +
                " ${formatSvgNumber(targetX)} ${formatSvgNumber(targetY)}"
            builder.group()
            builder.path(d: path)
            builder.className("chord-ribbon")
            builder.fill("none")
            builder.stroke(config.theme.colorAt(findNode(nodes, link.source)))
            builder.strokeWidth(chordWidth(link.value, maxValue))
            builder.strokeOpacity(0.35)
            builder.end()
        }
        if (showLabels) {
            for (node in nodes) {
                let labelX = centerX + (radius + 16.0) * cos(node.midAngle)
                let labelY = centerY + (radius + 16.0) * sin(node.midAngle)
                kit.text(
                    labelX, labelY, node.name,
                    size: config.theme.fontSize,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "chord-label"
                )
            }
        }
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<ChordNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }
}

/** 圆弧路径。 */
internal func chordArcPath(
    centerX: Float64,
    centerY: Float64,
    radius: Float64,
    startAngle: Float64,
    endAngle: Float64
): String {
    let startX = centerX + radius * cos(startAngle)
    let startY = centerY + radius * sin(startAngle)
    let endX = centerX + radius * cos(endAngle)
    let endY = centerY + radius * sin(endAngle)
    let largeArc = if (endAngle - startAngle > 3.141592653589793) { 1 } else { 0 }
    "M ${formatSvgNumber(startX)} ${formatSvgNumber(startY)}" +
        " A ${formatSvgNumber(radius)} ${formatSvgNumber(radius)} 0 ${largeArc} 1" +
        " ${formatSvgNumber(endX)} ${formatSvgNumber(endY)}"
}

/** 链接值 → 带状线宽：1px 到 7px。 */
internal func chordWidth(value: Float64, maxValue: Float64): Float64 {
    if (value <= 0.0 || maxValue <= 0.0) {
        return 1.0
    }
    let ratio = minFloat(value / maxValue, 1.0)
    1.0 + 6.0 * sqrt(ratio)
}
