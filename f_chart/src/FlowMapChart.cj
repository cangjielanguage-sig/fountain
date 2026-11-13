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

/** 流向地图区域。 */
internal class FlowMapRegion {
    let id: String
    let name: String
    let path: String
    let centerX: Float64
    let centerY: Float64

    init(id: String, name: String, path: String, centerX: Float64, centerY: Float64) {
        this.id = id
        this.name = name
        this.path = path
        this.centerX = centerX
        this.centerY = centerY
    }
}

/** 流向地图中的一条流。 */
internal class FlowMapFlow {
    let source: String
    let target: String
    let value: Float64
    let points: Array<Array<Float64>>

    init(source: String, target: String, value: Float64, points: Array<Array<Float64>>) {
        this.source = source
        this.target = target
        this.value = value
        this.points = points
    }
}

/** M60 流向地图。 */
public class FlowMapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "flow-map")
        let root = ChartJson.of(data)
        let viewBoxValues = root.numberArray("viewBox")
        var viewMinX = 0.0
        var viewMinY = 0.0
        var viewWidth = config.width
        var viewHeight = config.height
        if (!viewBoxValues.isEmpty()) {
            if (viewBoxValues.size != 4 || viewBoxValues[2] <= 0.0 || viewBoxValues[3] <= 0.0) {
                throw chartInvalidValue("viewBox", "期望 [x, y, w, h] 且宽高大于 0")
            }
            viewMinX = viewBoxValues[0]
            viewMinY = viewBoxValues[1]
            viewWidth = viewBoxValues[2]
            viewHeight = viewBoxValues[3]
        }

        let regionArray = root.requiredArray("regions")
        let regionItems = regionArray.getItems()
        if (regionItems.isEmpty()) {
            throw chartInvalidValue("regions", "至少需要一个区域")
        }
        let regions = ArrayList<FlowMapRegion>()
        var regionIndex = 0
        for (item in regionItems) {
            let itemPath = "regions[${regionIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望区域对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let id = json.requiredString("id")
            for (existing in regions) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "区域 id 重复")
                }
            }
            let name = json.string("name", default: id)
            let path = json.requiredString("path")
            let center = pathCentroid(path)
            regions.add(FlowMapRegion(id, name, path, center[0], center[1]))
            regionIndex++
        }

        let flowArray = root.requiredArray("flows")
        let flowItems = flowArray.getItems()
        if (flowItems.isEmpty()) {
            throw chartInvalidValue("flows", "至少需要一条流向")
        }
        let flows = ArrayList<FlowMapFlow>()
        var maxValue = 0.0
        var flowIndex = 0
        for (item in flowItems) {
            let itemPath = "flows[${flowIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望流向对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let source = match (json.string("source")) {
                case Some(value) => value
                case None => json.requiredString("from")
            }
            let target = match (json.string("target")) {
                case Some(value) => value
                case None => json.requiredString("to")
            }
            if (findRegion(regions, source) < 0) {
                throw chartInvalidValue("${itemPath}.source", "区域 ${source} 不存在")
            }
            if (findRegion(regions, target) < 0) {
                throw chartInvalidValue("${itemPath}.target", "区域 ${target} 不存在")
            }
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            if (value <= 0.0) {
                throw chartInvalidValue("${itemPath}.value", "流量必须大于 0")
            }
            maxValue = maxFloat(maxValue, value)
            let points = ArrayList<Array<Float64>>()
            match (json.array("points")) {
                case Some(pointArray) =>
                    let pointItems = pointArray.getItems()
                    var pointIndex = 0
                    for (pointItem in pointItems) {
                        let pointPath = "${itemPath}.points[${pointIndex}]"
                        if (!pointItem.kind.isArray) {
                            throw chartInvalidValue(pointPath, "期望 [x, y] 坐标")
                        }
                        let values = pointItem.asArray().getItems()
                        if (values.size != 2) {
                            throw chartInvalidValue(pointPath, "期望两个数字")
                        }
                        let x = jsonNumberValue(values[0], "${pointPath}[0]")
                        let y = jsonNumberValue(values[1], "${pointPath}[1]")
                        points.add([x, y])
                        pointIndex++
                    }
                case None => ()
            }
            flows.add(FlowMapFlow(source, target, value, points.toArray()))
            flowIndex++
        }

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(viewMinX, viewMinY, viewWidth, viewHeight)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.rect(
            viewMinX, viewMinY, viewWidth, viewHeight,
            fill: config.theme.background, className: "background"
        )
        if (!config.title.isEmpty()) {
            kit.text(
                viewMinX + viewWidth / 2.0,
                viewMinY + config.padding.top + config.titleFontSize,
                config.title,
                size: config.titleFontSize,
                color: config.titleColor,
                anchor: "middle",
                className: "title"
            )
        }
        for (region in regions) {
            kit.path(
                region.path,
                fill: "#f0f0f0",
                stroke: "#cccccc",
                strokeWidth: 0.8,
                className: "flow-map-region"
            )
        }

        let color = config.theme.colorAt(0)
        let sorted = sortFlows(flows)
        for (flow in sorted) {
            let source = regions[findRegion(regions, flow.source)]
            let target = regions[findRegion(regions, flow.target)]
            let path = StringBuilder()
            if (flow.points.isEmpty()) {
                path.append(
                    "M ${formatSvgNumber(source.centerX)} ${formatSvgNumber(source.centerY)}"
                )
                path.append(" L ${formatSvgNumber(target.centerX)} ${formatSvgNumber(target.centerY)}")
            } else {
                for (pointIndex in 0..flow.points.size) {
                    let prefix = if (pointIndex == 0) { "M" } else { "L" }
                    path.append(
                        " ${prefix} ${formatSvgNumber(flow.points[pointIndex][0])} " +
                        "${formatSvgNumber(flow.points[pointIndex][1])}"
                    )
                }
            }
            builder.group()
            builder.path(d: path.toString())
            builder.className("flow-map-path")
            builder.fill("none")
            builder.stroke(color)
            builder.strokeWidth(flowMapWidth(flow.value, maxValue))
            builder.strokeOpacity(0.6)
            builder.end()
        }
        builder.toSvgString()
    }

    private func findRegion(regions: ArrayList<FlowMapRegion>, id: String): Int64 {
        for (index in 0..regions.size) {
            if (regions[index].id == id) {
                return index
            }
        }
        -1
    }

    private func sortFlows(flows: ArrayList<FlowMapFlow>): Array<FlowMapFlow> {
        let sorted = ArrayList<FlowMapFlow>()
        for (flow in flows) {
            sorted.add(flow)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && sorted[j].value < sorted[j - 1].value) {
                let temporary = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = temporary
                j--
            }
        }
        sorted.toArray()
    }
}

/** 流量 → 线宽：1px（0）到 5px（最大值）。 */
internal func flowMapWidth(value: Float64, maxValue: Float64): Float64 {
    if (value <= 0.0 || maxValue <= 0.0) {
        return 1.0
    }
    let ratio = minFloat(value / maxValue, 1.0)
    1.0 + 4.0 * sqrt(ratio)
}
