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

/** 蜂巢图节点。 */
internal class HiveNode {
    let id: String
    let name: String
    let group: String
    var x: Float64
    var y: Float64

    init(id: String, name: String, group: String) {
        this.id = id
        this.name = name
        this.group = group
        this.x = 0.0
        this.y = 0.0
    }
}

/** 蜂巢图链接。 */
internal class HiveLink {
    let source: String
    let target: String
    let value: Float64

    init(source: String, target: String, value: Float64) {
        this.source = source
        this.target = target
        this.value = value
    }
}

/** M65 蜂巢图：按分组聚簇。 */
public class HiveChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "hive")
        let root = ChartJson.of(data)
        let groupField = root.string("groupField", default: "group")
        if (groupField.isEmpty()) {
            throw chartInvalidValue("groupField", "字段名不能为空")
        }
        let nodeRadius = root.number("nodeRadius", default: 10.0)
        if (nodeRadius <= 0.0) {
            throw chartInvalidValue("nodeRadius", "节点半径必须大于 0")
        }
        let clusterGap = root.number("clusterGap", default: 80.0)
        if (clusterGap <= 0.0) {
            throw chartInvalidValue("clusterGap", "簇间距必须大于 0")
        }

        let nodeArray = root.requiredArray("nodes")
        let nodeItems = nodeArray.getItems()
        if (nodeItems.isEmpty()) {
            throw chartInvalidValue("nodes", "至少需要一个节点")
        }
        let nodes = ArrayList<HiveNode>()
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
            let group = json.string(groupField, default: "")
            nodes.add(HiveNode(id, name, group))
            nodeIndex++
        }

        let linkArray = root.requiredArray("links")
        let linkItems = linkArray.getItems()
        if (linkItems.isEmpty()) {
            throw chartInvalidValue("links", "至少需要一条链接")
        }
        let links = ArrayList<HiveLink>()
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
            links.add(HiveLink(source, target, value))
            linkIndex++
        }

        let groupNames = ArrayList<String>()
        let groupMembers = ArrayList<ArrayList<Int64>>()
        for (index in 0..nodes.size) {
            let group = nodes[index].group
            var position = -1
            for (groupIndex in 0..groupNames.size) {
                if (groupNames[groupIndex] == group) {
                    position = groupIndex
                    break
                }
            }
            if (position < 0) {
                groupNames.add(group)
                groupMembers.add(ArrayList<Int64>())
                position = groupNames.size - 1
            }
            groupMembers[position].add(index)
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let clusterRadius = minFloat(frame.plot.width, frame.plot.height) * 0.32
        let localRadius = minFloat(clusterGap / 2.0, nodeRadius * 2.2)
        for (groupIndex in 0..groupNames.size) {
            let members = groupMembers[groupIndex]
            let angle = if (groupNames.size == 1) {
                0.0
            } else {
                -3.141592653589793 / 2.0 +
                2.0 * 3.141592653589793 * Float64(groupIndex) / Float64(groupNames.size)
            }
            let clusterX = if (groupNames.size == 1) {
                centerX
            } else {
                centerX + clusterRadius * cos(angle)
            }
            let clusterY = if (groupNames.size == 1) {
                centerY
            } else {
                centerY + clusterRadius * sin(angle)
            }
            for (memberIndex in 0..members.size) {
                let node = nodes[members[memberIndex]]
                if (members.size == 1) {
                    node.x = clusterX
                    node.y = clusterY
                } else {
                    let memberAngle = -3.141592653589793 / 2.0 +
                        2.0 * 3.141592653589793 * Float64(memberIndex) / Float64(members.size)
                    node.x = clusterX + localRadius * cos(memberAngle)
                    node.y = clusterY + localRadius * sin(memberAngle)
                }
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

        for (link in links) {
            let source = nodes[findNode(nodes, link.source)]
            let target = nodes[findNode(nodes, link.target)]
            kit.line(
                source.x, source.y, target.x, target.y,
                stroke: "#b0b0b0", strokeWidth: 1.2, className: "hive-link"
            )
        }
        for (node in nodes) {
            let color = config.theme.colorAt(flameColorIndex(node.group, config.theme.palette.size))
            kit.circle(node.x, node.y, nodeRadius, fill: color, className: "hive-node")
            kit.text(
                node.x, node.y, node.name,
                size: minFloat(config.theme.fontSize - 2.0, nodeRadius * 0.9),
                color: "#ffffff",
                anchor: "middle",
                className: "hive-label"
            )
        }
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<HiveNode>, id: String): Int64 {
        for (index in 0..nodes.size) {
            if (nodes[index].id == id) {
                return index
            }
        }
        -1
    }
}
