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

/** 矩形树图节点。 */
internal class TreemapNode {
    let id: String
    let name: String
    let parent: ?String
    let value: ?Float64
    let children: ArrayList<TreemapNode>

    init(id: String, name: String, parent: ?String, value: ?Float64) {
        this.id = id
        this.name = name
        this.parent = parent
        this.value = value
        this.children = ArrayList<TreemapNode>()
    }
}

/**
 * M34 矩形树图。
 *
 * 按层级节点值分配矩形面积，叶子绘制为色块。
 */
public class TreemapChart <: Chart {
    private var leafIndex: Int64 = 0

    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "treemap")
        let root = ChartJson.of(data)
        let nodesArray = root.requiredArray("nodes")
        let items = nodesArray.getItems()
        if (items.isEmpty()) {
            throw chartMissingField("nodes")
        }
        let parsed = ArrayList<TreemapNode>()
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
            for (existing in parsed) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "节点 id 重复")
                }
            }
            let name = json.string("name", default: id)
            let parent = match (json.value("parent")) {
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
            let value = match (json.value("value")) {
                case Some(entry) =>
                    if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                        throw chartInvalidValue("${itemPath}.value", "期望数字")
                    }
                    let numeric = jsonNumberValue(entry, "${itemPath}.value")
                    if (numeric <= 0.0) {
                        throw chartInvalidValue("${itemPath}.value", "叶子值必须大于 0")
                    }
                    Some(numeric)
                case None => None<Float64>
            }
            parsed.add(TreemapNode(id, name, parent, value))
            index++
        }
        let roots = ArrayList<TreemapNode>()
        for (node in parsed) {
            match (node.parent) {
                case Some(parentId) =>
                    match (findNode(parsed, parentId)) {
                        case Some(parentNode) => parentNode.children.add(node)
                        case None =>
                            throw chartInvalidValue("nodes", "父节点 ${parentId} 不存在")
                    }
                case None => roots.add(node)
            }
        }
        if (roots.size != 1) {
            throw chartInvalidValue("nodes", "必须恰好有一个根节点")
        }
        let tiling = root.string("tiling", default: "squarify")
        if (tiling != "squarify") {
            throw chartInvalidValue("tiling", "目前仅支持 squarify")
        }

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
        this.leafIndex = 0
        let left = config.padding.left + 20.0
        let top = config.padding.top + 60.0
        let width = config.width - config.padding.left - config.padding.right - 40.0
        let height = config.height - config.padding.top - config.padding.bottom - 80.0
        layoutNode(kit, config, roots[0], left, top, width, height)
        builder.toSvgString()
    }

    private func findNode(nodes: ArrayList<TreemapNode>, id: String): ?TreemapNode {
        for (node in nodes) {
            if (node.id == id) {
                return Some(node)
            }
        }
        None<TreemapNode>
    }

    private func nodeValue(node: TreemapNode): Float64 {
        if (node.children.isEmpty()) {
            match (node.value) {
                case Some(value) => value
                case None => 0.0
            }
        } else {
            var total = 0.0
            for (child in node.children) {
                total += nodeValue(child)
            }
            total
        }
    }

    private func sortChildren(node: TreemapNode): Array<TreemapNode> {
        let sorted = ArrayList<TreemapNode>()
        for (child in node.children) {
            sorted.add(child)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && nodeValue(sorted[j]) > nodeValue(sorted[j - 1])) {
                let temporary = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = temporary
                j--
            }
        }
        sorted.toArray()
    }

    private func layoutNode(
        kit: ChartSvgKit,
        config: ChartConfig,
        node: TreemapNode,
        x: Float64,
        y: Float64,
        width: Float64,
        height: Float64
    ): Unit {
        if (node.children.isEmpty()) {
            let color = config.theme.colorAt(this.leafIndex)
            this.leafIndex++
            kit.rect(
                x, y, width, height,
                fill: color, stroke: "#ffffff", strokeWidth: 1.0,
                className: "treemap-cell"
            )
            if (width > 40.0 && height > 18.0) {
                kit.text(
                    x + width / 2.0,
                    y + height / 2.0 + config.theme.fontSize / 3.0,
                    node.name,
                    size: config.theme.fontSize,
                    color: "#ffffff",
                    anchor: "middle",
                    className: "treemap-label"
                )
            }
            return
        }
        let total = nodeValue(node)
        if (total <= 0.0) {
            return
        }
        let children = sortChildren(node)
        var cursorX = x
        var cursorY = y
        var remainingWidth = width
        var remainingHeight = height
        for (child in children) {
            let ratio = nodeValue(child) / total
            if (remainingWidth >= remainingHeight) {
                let childWidth = width * ratio
                layoutNode(kit, config, child, cursorX, cursorY, childWidth, remainingHeight)
                cursorX += childWidth
                remainingWidth -= childWidth
            } else {
                let childHeight = height * ratio
                layoutNode(kit, config, child, cursorX, cursorY, remainingWidth, childHeight)
                cursorY += childHeight
                remainingHeight -= childHeight
            }
        }
    }
}

/** 叶子值 → 面积权重，总和为 1。 */
internal func treemapWeights(values: Array<Float64>): Array<Float64> {
    var total = 0.0
    for (value in values) {
        if (value <= 0.0) {
            throw chartInvalidValue("nodes", "叶子值必须大于 0")
        }
        total += value
    }
    if (total <= 0.0) {
        throw chartInvalidValue("nodes", "节点总值必须大于 0")
    }
    let weights = ArrayList<Float64>()
    for (value in values) {
        weights.add(value / total)
    }
    weights.toArray()
}
