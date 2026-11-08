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

import std.collection.{ArrayList, HashMap}
import std.math.*
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

internal class GanttTask {
    let id: String
    let name: String
    let startDay: Float64
    let endDay: Float64
    let progress: Float64
    let dependsOn: Array<String>
    let color: ?String

    init(
        id: String,
        name: String,
        startDay: Float64,
        endDay: Float64,
        progress: Float64,
        dependsOn: Array<String>,
        color: ?String
    ) {
        this.id = id
        this.name = name
        this.startDay = startDay
        this.endDay = endDay
        this.progress = progress
        this.dependsOn = dependsOn
        this.color = color
    }
}

/** M8 甘特图：任务时间区间、进度与依赖。 */
public class GanttChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "gantt")
        let root = ChartJson.of(data)
        let tasksArray = root.requiredArray("tasks")
        if (tasksArray.getItems().isEmpty()) {
            throw chartMissingField("tasks")
        }
        let tasks = parseTasks(tasksArray)
        let taskIndex = HashMap<String, Int64>()
        for (index in 0..tasks.size) {
            taskIndex[tasks[index].id] = index
        }
        for (index in 0..tasks.size) {
            for (dependency in tasks[index].dependsOn) {
                if (!taskIndex.contains(dependency)) {
                    throw chartInvalidValue(
                        "tasks[${index}].dependsOn",
                        "依赖的任务 ${dependency} 不存在"
                    )
                }
            }
        }

        var minDay = tasks[0].startDay
        var maxDay = tasks[0].endDay
        for (task in tasks) {
            minDay = minFloat(minDay, task.startDay)
            maxDay = maxFloat(maxDay, task.endDay)
        }
        minDay -= 2.0
        maxDay += 2.0
        let ticks = chartNiceTicks(minDay, maxDay, config.xAxis.tickCount)
        let tickLabels = ArrayList<String>()
        for (tick in ticks) {
            tickLabels.add(ChartTime.formatDays(tick))
        }

        var maxLabelWidth = 0.0
        for (task in tasks) {
            let width = chartTextWidth(task.name, config.theme.fontSize)
            if (width > maxLabelWidth) {
                maxLabelWidth = width
            }
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, false, maxLabelWidth + 12.0, xLabelHeight)
        let xScale = LinearScale(minDay, maxDay, frame.plot.right(), frame.plot.x)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        for (tick in ticks) {
            let x = xScale.scale(tick)
            kit.line(
                x, frame.plot.y, x, frame.plot.bottom(),
                stroke: config.theme.gridColor, strokeWidth: 1.0, className: "grid"
            )
        }

        let rowHeight = frame.plot.height / Float64(tasks.size)
        let barHeight = minFloat(18.0, rowHeight * 0.6)
        for (index in 0..tasks.size) {
            let task = tasks[index]
            let centerY = frame.plot.y + (Float64(index) + 0.5) * rowHeight
            let x1 = xScale.scale(task.startDay)
            let x2 = xScale.scale(task.endDay)
            let width = maxFloat(2.0, x2 - x1)
            let color = match (task.color) {
                case Some(value) => value
                case None => config.theme.colorAt(index)
            }
            kit.rect(
                x1, centerY - barHeight / 2.0, width, barHeight,
                fill: color, className: "gantt-bar", radius: Some(2.0)
            )
            if (task.progress > 0.0) {
                kit.rect(
                    x1, centerY - barHeight / 2.0, width * task.progress, barHeight,
                    fill: color, className: "progress", fillOpacity: 0.55
                )
            }
            kit.text(
                frame.plot.x - 8.0, centerY, task.name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "task-label"
            )
        }

        for (index in 0..tasks.size) {
            let task = tasks[index]
            for (dependency in task.dependsOn) {
                let dependencyIndex = taskIndex[dependency]
                let fromX = xScale.scale(tasks[dependencyIndex].endDay)
                let fromY = frame.plot.y + (Float64(dependencyIndex) + 0.5) * rowHeight
                let toX = xScale.scale(task.startDay)
                let toY = frame.plot.y + (Float64(index) + 0.5) * rowHeight
                let midX = (fromX + toX) / 2.0
                let path = "M ${formatSvgNumber(fromX)} ${formatSvgNumber(fromY)} " +
                    "L ${formatSvgNumber(midX)} ${formatSvgNumber(fromY)} " +
                    "L ${formatSvgNumber(midX)} ${formatSvgNumber(toY)} " +
                    "L ${formatSvgNumber(toX)} ${formatSvgNumber(toY)}"
                kit.path(
                    path, fill: "none", stroke: config.theme.axisColor,
                    strokeWidth: 1.0, className: "dependency"
                )
                let arrow = "M ${formatSvgNumber(toX)} ${formatSvgNumber(toY)} " +
                    "L ${formatSvgNumber(toX - 6.0)} ${formatSvgNumber(toY - 4.0)} " +
                    "L ${formatSvgNumber(toX - 6.0)} ${formatSvgNumber(toY + 4.0)} Z"
                kit.path(arrow, fill: config.theme.axisColor, className: "dependency-arrow")
            }
        }

        frame.drawXAxisNumeric(kit, ticks, xScale, tickLabels.toArray())
        builder.toSvgString()
    }

    private func parseTasks(items: JsonArray): Array<GanttTask> {
        let tasks = ArrayList<GanttTask>()
        var index = 0
        for (item in items.getItems()) {
            let path = "tasks[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let id = json.requiredString("id")
            let name = json.string("name", default: id)
            let startDay = ChartTime.parseDays(json.requiredString("start"), "${path}.start")
            let endDay = ChartTime.parseDays(json.requiredString("end"), "${path}.end")
            if (endDay <= startDay) {
                throw chartInvalidValue("${path}.end", "结束日期必须晚于开始日期")
            }
            let progress = json.number("progress", default: 0.0)
            if (progress < 0.0 || progress > 1.0) {
                throw chartInvalidValue("${path}.progress", "progress 必须在 0–1 之间")
            }
            let dependsOn = json.stringArray("dependsOn", default: Array<String>())
            let color = json.string("color")
            tasks.add(GanttTask(id, name, startDay, endDay, progress, dependsOn, color))
            index++
        }
        tasks.toArray()
    }
}
