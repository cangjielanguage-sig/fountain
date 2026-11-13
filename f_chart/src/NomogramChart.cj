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
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 列线图变量。 */
internal class NomogramVariable {
    let name: String
    let rangeMin: Float64
    let rangeMax: Float64

    init(name: String, rangeMin: Float64, rangeMax: Float64) {
        this.name = name
        this.rangeMin = rangeMin
        this.rangeMax = rangeMax
    }
}

/** 列线图风险映射点。 */
internal class NomogramRisk {
    let points: Float64
    let probability: Float64

    init(points: Float64, probability: Float64) {
        this.points = points
        this.probability = probability
    }
}

/** M51 列线图。 */
public class NomogramChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "nomogram")
        let root = ChartJson.of(data)
        let variableArray = root.requiredArray("variables")
        let variableItems = variableArray.getItems()
        if (variableItems.isEmpty()) {
            throw chartInvalidValue("variables", "至少需要一个变量")
        }
        let variables = ArrayList<NomogramVariable>()
        var index = 0
        for (item in variableItems) {
            let path = "variables[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.requiredString("name")
            let range = parsePair(json.requiredArray("range"), "${path}.range")
            if (range[0] >= range[1]) {
                throw chartInvalidValue("${path}.range", "range 必须递增")
            }
            let points = parsePair(json.requiredArray("points"), "${path}.points")
            if (points[0] >= points[1]) {
                throw chartInvalidValue("${path}.points", "points 必须递增")
            }
            variables.add(NomogramVariable(name, range[0], range[1]))
            index++
        }

        let totalPoints = parsePair(root.requiredArray("totalPoints"), "totalPoints")
        if (totalPoints[0] >= totalPoints[1]) {
            throw chartInvalidValue("totalPoints", "totalPoints 必须递增")
        }
        let riskArray = root.requiredArray("risk")
        let riskItems = riskArray.getItems()
        if (riskItems.isEmpty()) {
            throw chartInvalidValue("risk", "至少需要一个风险映射点")
        }
        let risks = ArrayList<NomogramRisk>()
        var riskIndex = 0
        for (item in riskItems) {
            let path = "risk[${riskIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let points = jsonNumberValue(json.required("points"), "${path}.points")
            let probability = jsonNumberValue(
                json.required("probability"), "${path}.probability"
            )
            if (points < totalPoints[0] || points > totalPoints[1]) {
                throw chartInvalidValue("${path}.points", "风险点必须落在 totalPoints 范围内")
            }
            if (probability < 0.0 || probability > 1.0) {
                throw chartInvalidValue("${path}.probability", "概率必须在 0–1 之间")
            }
            risks.add(NomogramRisk(points, probability))
            riskIndex++
        }

        var maxNameWidth = chartTextWidth("风险", config.theme.fontSize)
        for (variable in variables) {
            maxNameWidth = maxNameWidthOf(
                maxNameWidth, chartTextWidth(variable.name, config.theme.fontSize)
            )
        }
        let totalNameWidth = chartTextWidth("总分", config.theme.fontSize)
        if (totalNameWidth > maxNameWidth) {
            maxNameWidth = totalNameWidth
        }
        let frame = ChartFrame(config, false, maxNameWidth + 12.0, 8.0)
        let rowCount = variables.size + 2
        let rowHeight = frame.plot.height / Float64(rowCount)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        for (variableIndex in 0..variables.size) {
            let variable = variables[variableIndex]
            let y = frame.plot.y + (Float64(variableIndex) + 0.5) * rowHeight
            kit.line(
                frame.plot.x, y, frame.plot.right(), y,
                stroke: config.theme.axisColor, strokeWidth: 1.0,
                className: "nomogram-variable"
            )
            drawName(kit, frame, y, variable.name, config)
            kit.text(
                frame.plot.x, y + config.theme.fontSize + 2.0,
                chartFormatTick(variable.rangeMin, "{value}"),
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "start",
                className: "nomogram-tick"
            )
            kit.text(
                frame.plot.right(), y + config.theme.fontSize + 2.0,
                chartFormatTick(variable.rangeMax, "{value}"),
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "nomogram-tick"
            )
        }

        let totalY = frame.plot.y + (Float64(variables.size) + 0.5) * rowHeight
        kit.line(
            frame.plot.x, totalY, frame.plot.right(), totalY,
            stroke: config.theme.textColor, strokeWidth: 1.5,
            className: "nomogram-total"
        )
        drawName(kit, frame, totalY, "总分", config)
        kit.text(
            frame.plot.x, totalY + config.theme.fontSize + 2.0,
            chartFormatTick(totalPoints[0], "{value}"),
            size: config.theme.fontSize,
            color: config.theme.axisColor,
            anchor: "start",
            className: "nomogram-tick"
        )
        kit.text(
            frame.plot.right(), totalY + config.theme.fontSize + 2.0,
            chartFormatTick(totalPoints[1], "{value}"),
            size: config.theme.fontSize,
            color: config.theme.axisColor,
            anchor: "end",
            className: "nomogram-tick"
        )

        let riskY = frame.plot.y + (Float64(variables.size + 1) + 0.5) * rowHeight
        kit.line(
            frame.plot.x, riskY, frame.plot.right(), riskY,
            stroke: config.theme.axisColor, strokeWidth: 1.0,
            className: "nomogram-risk-axis"
        )
        drawName(kit, frame, riskY, "风险", config)
        for (risk in risks) {
            let x = frame.plot.x +
                nomogramPosition(risk.points, totalPoints[0], totalPoints[1]) * frame.plot.width
            kit.line(
                x, riskY - 4.0, x, riskY + 4.0,
                stroke: config.theme.axisColor, strokeWidth: 1.0,
                className: "nomogram-risk-tick"
            )
            kit.text(
                x, riskY + config.theme.fontSize + 4.0,
                chartFormatTick(risk.probability, "{value}"),
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "middle",
                className: "nomogram-risk-label"
            )
        }
        builder.toSvgString()
    }

    private func parsePair(array: JsonArray, path: String): Array<Float64> {
        let items = array.getItems()
        if (items.size != 2) {
            throw chartInvalidValue(path, "期望两个数字")
        }
        let values = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            values.add(jsonNumberValue(item, "${path}[${index}]"))
            index++
        }
        [values[0], values[1]]
    }

    private func drawName(kit: ChartSvgKit, frame: ChartFrame, y: Float64, name: String, config: ChartConfig): Unit {
        kit.text(
            frame.plot.x - 8.0, y, name,
            size: config.theme.fontSize,
            color: config.theme.textColor,
            anchor: "end",
            className: "nomogram-name"
        )
    }

    private func maxNameWidthOf(left: Float64, right: Float64): Float64 {
        if (left > right) { left } else { right }
    }
}

/** 列线图位置：线性归一化并夹到 0–1。 */
internal func nomogramPosition(value: Float64, minValue: Float64, maxValue: Float64): Float64 {
    if (maxValue <= minValue) {
        return 0.0
    }
    var ratio = (value - minValue) / (maxValue - minValue)
    if (ratio < 0.0) {
        ratio = 0.0
    }
    if (ratio > 1.0) {
        ratio = 1.0
    }
    ratio
}
