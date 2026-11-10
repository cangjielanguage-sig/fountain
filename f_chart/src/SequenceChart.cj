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

internal class Participant {
    let id: String
    let name: String

    init(id: String, name: String) {
        this.id = id
        this.name = name
    }
}

internal class SequenceMessage {
    let from: String
    let to: String
    let text: String
    let messageType: String
    let dashed: Bool
    let note: String

    init(from: String, to: String, text: String, messageType: String, dashed: Bool, note: String) {
        this.from = from
        this.to = to
        this.text = text
        this.messageType = messageType
        this.dashed = dashed
        this.note = note
    }
}

/** M10 时序图：参与者、生命线与消息。 */
public class SequenceChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "sequence")
        let root = ChartJson.of(data)
        let participantsArray = root.requiredArray("participants")
        if (participantsArray.getItems().isEmpty()) {
            throw chartMissingField("participants")
        }
        let participants = parseParticipants(participantsArray)
        let idMap = HashMap<String, Int64>()
        for (index in 0..participants.size) {
            if (idMap.contains(participants[index].id)) {
                throw chartInvalidValue("participants[${index}].id", "参与者 id 重复")
            }
            idMap[participants[index].id] = index
        }
        let messages = parseMessages(root, idMap)

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let count = participants.size
        let columnWidth = frame.plot.width / Float64(count)
        let boxWidth = minFloat(140.0, columnWidth * 0.8)
        let headerHeight = 36.0
        let headerY = frame.plot.y
        let centers = Array<Float64>(count, repeat: 0.0)
        for (index in 0..count) {
            let center = frame.plot.x + columnWidth * (Float64(index) + 0.5)
            centers[index] = center
            let fill = if (config.theme.background == "none") { "#ffffff" } else { config.theme.background }
            kit.rect(
                center - boxWidth / 2.0, headerY, boxWidth, headerHeight,
                fill: fill, stroke: config.theme.axisColor,
                className: "participant", radius: Some(4.0)
            )
            kit.text(
                center, headerY + headerHeight / 2.0, participants[index].name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "participant-label"
            )
            kit.line(
                center, headerY + headerHeight, center, frame.plot.bottom(),
                stroke: config.theme.axisColor, strokeWidth: 1.0,
                className: "lifeline", dash: "4 4"
            )
        }

        let startY = headerY + headerHeight + 30.0
        let available = frame.plot.bottom() - startY
        let rowHeight = if (messages.isEmpty()) {
            40.0
        } else {
            minFloat(40.0, available / Float64(messages.size))
        }
        for (index in 0..messages.size) {
            let message = messages[index]
            let fromX = centers[idMap[message.from]]
            let toX = centers[idMap[message.to]]
            let y = startY + Float64(index) * rowHeight + rowHeight / 2.0
            let dashed = message.dashed || message.messageType == "return"
            kit.line(
                fromX, y, toX, y,
                stroke: config.theme.textColor, strokeWidth: 1.2,
                className: "message", dash: if (dashed) { "5 3" } else { "" }
            )
            if (toX > fromX) {
                let arrow = "M ${formatSvgNumber(toX)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(toX - 8.0)} ${formatSvgNumber(y - 4.0)} " +
                    "L ${formatSvgNumber(toX - 8.0)} ${formatSvgNumber(y + 4.0)} Z"
                kit.path(arrow, fill: config.theme.textColor, className: "message-arrow")
            } else if (toX < fromX) {
                let arrow = "M ${formatSvgNumber(toX)} ${formatSvgNumber(y)} " +
                    "L ${formatSvgNumber(toX + 8.0)} ${formatSvgNumber(y - 4.0)} " +
                    "L ${formatSvgNumber(toX + 8.0)} ${formatSvgNumber(y + 4.0)} Z"
                kit.path(arrow, fill: config.theme.textColor, className: "message-arrow")
            }
            kit.text(
                (fromX + toX) / 2.0, y - 8.0, message.text,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "middle",
                className: "message-label"
            )
            if (!message.note.isEmpty()) {
                let noteWidth = 110.0
                let noteX = (fromX + toX) / 2.0 - noteWidth / 2.0
                kit.rect(
                    noteX, y + 5.0, noteWidth, 20.0,
                    fill: "#fffbe6", stroke: config.theme.gridColor,
                    className: "note", radius: Some(2.0)
                )
                kit.text(
                    noteX + noteWidth / 2.0, y + 15.0, message.note,
                    size: config.theme.fontSize - 1.0,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "note-label"
                )
            }
        }
        builder.toSvgString()
    }

    private func parseParticipants(items: JsonArray): Array<Participant> {
        let participants = ArrayList<Participant>()
        var index = 0
        for (item in items.getItems()) {
            let path = "participants[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let id = json.requiredString("id")
            participants.add(Participant(id, json.string("name", default: id)))
            index++
        }
        participants.toArray()
    }

    private func parseMessages(
        root: ChartJson,
        participants: HashMap<String, Int64>
    ): Array<SequenceMessage> {
        let messages = ArrayList<SequenceMessage>()
        let items = root.requiredArray("messages")
        var index = 0
        for (item in items.getItems()) {
            let path = "messages[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let from = json.requiredString("from")
            let to = json.requiredString("to")
            if (!participants.contains(from)) {
                throw chartInvalidValue("${path}.from", "发送方不存在")
            }
            if (!participants.contains(to)) {
                throw chartInvalidValue("${path}.to", "接收方不存在")
            }
            messages.add(SequenceMessage(
                from, to,
                json.string("text", default: ""),
                json.string("type", default: "sync"),
                json.bool("dashed", default: false),
                json.string("note", default: "")
            ))
            index++
        }
        messages.toArray()
    }
}
