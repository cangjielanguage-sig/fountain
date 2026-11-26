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

/** 时间线图的一个事件。 */
internal class TimelineEvent {
    let date: String
    let title: String
    let description: String
    let group: Option<String>

    init(date: String, title: String, description: String, group: Option<String>) {
        this.date = date
        this.title = title
        this.description = description
        this.group = group
    }
}

/** M81 时间线图。 */
public class TimelineChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "timeline")
        let root = ChartJson.of(data)
        let orientation = root.string("orientation", default: "horizontal")
        if (orientation != "horizontal" && orientation != "vertical") {
            throw chartInvalidValue("orientation", "仅支持 horizontal 或 vertical")
        }
        let eventArray = root.requiredArray("events")
        let eventItems = eventArray.getItems()
        if (eventItems.isEmpty()) {
            throw chartInvalidValue("events", "至少需要一个事件")
        }
        let events = ArrayList<TimelineEvent>()
        var eventIndex = 0
        for (item in eventItems) {
            let itemPath = "events[${eventIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望事件对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let date = json.requiredString("date")
            let title = json.requiredString("title")
            events.add(TimelineEvent(
                date,
                title,
                json.string("description", default: ""),
                json.string("group")
            ))
            eventIndex++
        }
        let eventArrayValue = events.toArray()

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let plot = frame.plot
        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.background(config.width, config.height)
        frame.drawTitle(kit)

        if (orientation == "horizontal") {
            drawHorizontal(kit, config, plot, eventArrayValue)
        } else {
            drawVertical(kit, config, plot, eventArrayValue)
        }
        builder.toSvgString()
    }

    private func drawHorizontal(
        kit: ChartSvgKit,
        config: ChartConfig,
        plot: ChartRect,
        events: Array<TimelineEvent>
    ): Unit {
        let axisY = plot.centerY()
        kit.line(
            plot.x + 20.0, axisY, plot.right() - 20.0, axisY,
            stroke: config.theme.axisColor, strokeWidth: 2.0,
            className: "timeline-axis"
        )
        let left = plot.x + 48.0
        let right = plot.right() - 48.0
        let count = events.size
        for (index in 0..count) {
            let x = if (count <= 1) {
                plot.centerX()
            } else {
                left + (right - left) * Float64(index) / Float64(count - 1)
            }
            let event = events[index]
            let color = eventColor(config, event, index)
            kit.circle(x, axisY, 5.0, fill: color, className: "timeline-dot")
            let above = index % 2 == 0
            let dateY = if (above) { axisY - 14.0 } else { axisY + 58.0 }
            let titleY = if (above) { axisY - 32.0 } else { axisY + 24.0 }
            let descY = if (above) { axisY - 50.0 } else { axisY + 42.0 }
            kit.text(
                x, dateY, event.date,
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "middle",
                className: "timeline-date"
            )
            kit.text(
                x, titleY, orgFitLabel(event.title, right - left, config.theme.fontSize),
                size: config.theme.fontSize + 1.0,
                color: color,
                anchor: "middle",
                className: "timeline-title"
            )
            if (!event.description.isEmpty()) {
                kit.text(
                    x, descY,
                    orgFitLabel(event.description, right - left, config.theme.fontSize),
                    size: config.theme.fontSize - 1.0,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "timeline-desc"
                )
            }
        }
    }

    private func drawVertical(
        kit: ChartSvgKit,
        config: ChartConfig,
        plot: ChartRect,
        events: Array<TimelineEvent>
    ): Unit {
        let axisX = plot.x + 72.0
        kit.line(
            axisX, plot.y + 20.0, axisX, plot.bottom() - 20.0,
            stroke: config.theme.axisColor, strokeWidth: 2.0,
            className: "timeline-axis"
        )
        let top = plot.y + 32.0
        let bottom = plot.bottom() - 32.0
        let count = events.size
        for (index in 0..count) {
            let y = if (count <= 1) {
                plot.centerY()
            } else {
                top + (bottom - top) * Float64(index) / Float64(count - 1)
            }
            let event = events[index]
            let color = eventColor(config, event, index)
            kit.circle(axisX, y, 5.0, fill: color, className: "timeline-dot")
            kit.text(
                axisX - 12.0, y + config.theme.fontSize / 3.0, event.date,
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "timeline-date"
            )
            kit.text(
                axisX + 16.0, y + config.theme.fontSize / 3.0,
                orgFitLabel(event.title, plot.right() - axisX - 24.0, config.theme.fontSize + 1.0),
                size: config.theme.fontSize + 1.0,
                color: color,
                className: "timeline-title"
            )
            if (!event.description.isEmpty()) {
                kit.text(
                    axisX + 16.0, y + config.theme.fontSize / 3.0 + 18.0,
                    orgFitLabel(
                        event.description, plot.right() - axisX - 24.0,
                        config.theme.fontSize - 1.0
                    ),
                    size: config.theme.fontSize - 1.0,
                    color: config.theme.textColor,
                    className: "timeline-desc"
                )
            }
        }
    }
}

/** 按 `group` 散列或事件下标选择调色板颜色。 */
internal func eventColor(config: ChartConfig, event: TimelineEvent, index: Int64): String {
    match (event.group) {
        case Some(name) =>
            var hash: Int64 = 0
            for (rune in name.runes()) {
                hash = hash * 31 + Int64(rune.position())
            }
            config.theme.colorAt(abs(hash))
        case None => config.theme.colorAt(index)
    }
}
