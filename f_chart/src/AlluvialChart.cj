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

/** 冲积图节点。 */
internal class AlluvialNode {
    let id: String
    let name: String
    let stageIndex: Int64
    var x: Float64
    var y: Float64
    var height: Float64
    var scale: Float64

    init(id: String, name: String, stageIndex: Int64) {
        this.id = id
        this.name = name
        this.stageIndex = stageIndex
        this.x = 0.0
        this.y = 0.0
        this.height = 0.0
        this.scale = 0.0
    }
}

/** 冲积图链接。 */
internal class AlluvialLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M66 冲积图。 */
public class AlluvialChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "alluvial")
        let root = ChartJson.of(data)
        let stageArray = match (root.array("stages")) {
            case Some(value) => value
            case None => throw chartMissingField("stages")
        }
        let stageItems = stageArray.getItems()
        if (stageItems.isEmpty()) {
            throw chartInvalidValue("stages", "至少需要一个阶段")
        }
        let stages = ArrayList<String>()
        var stageIndex = 0
        for (item in stageItems) {
            if (!item.kind.isString) {
                throw chartInvalidValue("stages[${stageIndex}]", "期望字符串")
            }
            stages.add(item.asString().value)
            stageIndex++
        }
        let nodeWidth = root.number("nodeWidth", default: 14.0)
        if (nodeWidth <= 0.0) {
            throw chartInvalidValue("nodeWidth", "节点宽度必须大于 0")
        }
        let nodeGap = root.number("nodeGap", default: 10.0)
        if (nodeGap < 0.0) {
            throw chartInvalidValue("nodeGap", "节点间距不能为负")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<AlluvialNode>()
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
            let stageName = json.requiredString("stage")
            let position = stageIndexOf(stages, stageName)
            if (position < 0) {
                throw chartInvalidValue("${itemPath}.stage", "阶段 ${stageName} 不在 stages 中")
            }
            nodes.add(AlluvialNode(id, json.string("name", default: id), position))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let linkItems = linkArray.getItems()
        if (linkItems.isEmpty()) {
            throw chartInvalidValue("links", "至少需要一条链接")
        }
        let links = ArrayList<AlluvialLink>()
        var inSums = Array<Float64>(nodes.size, repeat: 0.0)
        var outSums = Array<Float64>(nodes.size, repeat: 0.0)
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
            outSums[sourceIndex] += value
            inSums[targetIndex] += value
            links.add(AlluvialLink(source, target, value))
            linkIndex++
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        for (column in 0..stages.size) {
            let members = ArrayList<Int64>()
            for (index in 0..nodes.size) {
                if (nodes[index].stageIndex == column) {
                    members.add(index)
                }
            }
            if (members.isEmpty()) {
                continue
            }
            let totals = ArrayList<Float64>()
            for (index in members) {
                totals.add(maxFloat(inSums[index], outSums[index]))
            }
            let heights = alluvialHeights(totals.toArray(), frame.plot.height, nodeGap)
            var sumTotals = 0.0
            for (total in totals) {
                sumTotals += total
            }
            let usable = frame.plot.height - nodeGap * Float64(members.size - 1)
            let scale = if (sumTotals <= 0.0 || usable <= 0.0) { 0.0 } else { usable / sumTotals }
            let x = if (stages.size == 1) {
                frame.plot.x + (frame.plot.width - nodeWidth) / 2.0
            } else {
                frame.plot.x + (frame.plot.width - nodeWidth) *
                    Float64(column) / Float64(stages.size - 1)
            }
            var cursor = frame.plot.y
            for (memberIndex in 0..members.size) {
                let node = nodes[members[memberIndex]]
                node.x = x
                node.y = cursor
                node.height = heights[memberIndex]
                node.scale = scale
                cursor = cursor + heights[memberIndex] + nodeGap
            }
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

        for (index in 0..nodes.size) {
            let node = nodes[index]
            builder.group()
            builder.rect(x: node.x, y: node.y, width: nodeWidth, height: node.height)
            builder.className("alluvial-node")
            builder.fill(config.theme.colorAt(node.stageIndex))
            builder.end()
        }

        var outCursors = Array<Float64>(nodes.size, repeat: 0.0)
        var inCursors = Array<Float64>(nodes.size, repeat: 0.0)
        for (index in 0..nodes.size) {
            outCursors[index] = nodes[index].y
            inCursors[index] = nodes[index].y
        }
        for (link in links) {
            let sourceIndex = findNode(nodes, link.source)
            let targetIndex = findNode(nodes, link.target)
            let source = nodes[sourceIndex]
            let target = nodes[targetIndex]
            let sourceTop = outCursors[sourceIndex]
            let sourceBottom = sourceTop + link.value * source.scale
            outCursors[sourceIndex] = sourceBottom
            let targetTop = inCursors[targetIndex]
            let targetBottom = targetTop + link.value * target.scale
            inCursors[targetIndex] = targetBottom
            let sourceX = source.x + nodeWidth
            let targetX = target.x
            let midX = (sourceX + targetX) / 2.0
            let path = StringBuilder()
            path.append("M ${formatSvgNumber(sourceX)} ${formatSvgNumber(sourceTop)}")
            path.append(
                " C ${formatSvgNumber(midX)} ${formatSvgNumber(sourceTop)}" +
                " ${formatSvgNumber(midX)} ${formatSvgNumber(targetTop)}" +
                " ${formatSvgNumber(targetX)} ${formatSvgNumber(targetTop)}"
            )
            path.append(" L ${formatSvgNumber(targetX)} ${formatSvgNumber(targetBottom)}")
            path.append(
                " C ${formatSvgNumber(midX)} ${formatSvgNumber(targetBottom)}" +
                " ${formatSvgNumber(midX)} ${formatSvgNumber(sourceBottom)}" +
                " ${formatSvgNumber(sourceX)} ${formatSvgNumber(sourceBottom)}"
            )
            path.append(" Z")
            builder.group()
            builder.path(d: path.toString())
            builder.className("alluvial-link")
            builder.fill(config.theme.colorAt(source.stageIndex))
            builder.fillOpacity(0.35)
            builder.end()
        }

        for (node in nodes) {
            kit.text(
                node.x + nodeWidth + 4.0,
                node.y + node.height / 2.0,
                node.name,
                size: config.theme.fontSize - 2.0,
                color: config.theme.textColor,
                className: "alluvial-label"
            )
        }
        builder.toSvgString()
    }

    private func stageIndexOf(stages: ArrayList<String>, name: String): Int64 {
        for (index in 0..stages.size) {
            if (stages[index] == name) {
                return index
            }
        }
        -1
    }

    private func findNode(nodes: ArrayList<AlluvialNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }
}

/** 列内高度分配：扣除间距后按总量比例分配。 */
internal func alluvialHeights(totals: Array<Float64>, available: Float64, gap: Float64): Array<Float64> {
    let heights = ArrayList<Float64>()
    if (totals.isEmpty()) {
        return heights.toArray()
    }
    var sum = 0.0
    for (total in totals) {
        sum += total
    }
    let usable = available - gap * Float64(totals.size - 1)
    for (total in totals) {
        if (sum <= 0.0 || usable <= 0.0) {
            heights.add(0.0)
        } else {
            heights.add(total / sum * usable)
        }
    }
    heights.toArray()
}
