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

internal class WordCloudWord {
    let text: String
    let weight: Float64
    let color: String

    init(text: String, weight: Float64, color: String) {
        this.text = text
        this.weight = weight
        this.color = color
    }
}

/** M102 词云图。 */
public class WordCloudChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let root = ChartJson.of(data)
        let chartType = root.requiredString("type")
        let expectedType = if (chartType == "tag-cloud") { "tag-cloud" } else { "word-cloud" }
        let config = ChartConfig.parse(data, expectedType)
        let minFontSize = root.number("minFontSize", default: 12.0)
        let maxFontSize = root.number("maxFontSize", default: 64.0)
        if (minFontSize <= 0.0) {
            throw chartInvalidValue("minFontSize", "minFontSize 必须大于 0")
        }
        if (maxFontSize < minFontSize) {
            throw chartInvalidValue("maxFontSize", "maxFontSize 不能小于 minFontSize")
        }
        let rotations = ArrayList<Float64>()
        let rotateArray = root.value("rotate")
        match (rotateArray) {
            case Some(value) =>
                if (!value.kind.isArray) {
                    throw chartInvalidValue("rotate", "期望角度数组")
                }
                for (item in value.asArray().getItems()) {
                    if (!(item.kind.isInt || item.kind.isDecimal)) {
                        throw chartInvalidValue("rotate", "角度必须是数字")
                    }
                    let angle = jsonNumberValue(item, "rotate")
                    if (angle != 0.0 && angle != 90.0 && angle != -90.0) {
                        throw chartInvalidValue("rotate", "仅支持 0 / 90 / -90")
                    }
                    rotations.add(angle)
                }
            case None => rotations.add(0.0)
        }
        if (rotations.isEmpty()) {
            rotations.add(0.0)
        }

        let wordsArray = root.requiredArray("words")
        let wordItems = wordsArray.getItems()
        if (wordItems.isEmpty()) {
            throw chartInvalidValue("words", "词表不能为空")
        }
        let words = ArrayList<WordCloudWord>()
        var wordIndex = 0
        for (item in wordItems) {
            let itemPath = "words[${wordIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望词项对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let text = json.requiredString("text")
            if (text.isEmpty()) {
                throw chartInvalidValue("${itemPath}.text", "词语不能为空")
            }
            let weightValue = json.required("weight")
            if (!(weightValue.kind.isInt || weightValue.kind.isDecimal)) {
                throw chartInvalidValue("${itemPath}.weight", "权重必须是数字")
            }
            let weight = jsonNumberValue(weightValue, "${itemPath}.weight")
            if (weight <= 0.0) {
                throw chartInvalidValue("${itemPath}.weight", "权重必须大于 0")
            }
            let color = json.string("color", default: "")
            words.add(WordCloudWord(text, weight, color))
            wordIndex++
        }
        let ordered = wordCloudOrder(words)
        var minWeight = ordered[0].weight
        var maxWeight = ordered[0].weight
        for (word in ordered) {
            minWeight = minFloat(minWeight, word.weight)
            maxWeight = maxFloat(maxWeight, word.weight)
        }

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

        var cursorX = frame.plot.x
        var cursorY = frame.plot.y
        var rowHeight = 0.0
        let gap = 10.0
        for (index in 0..ordered.size) {
            let word = ordered[index]
            let fontSize = wordCloudFontSize(
                word.weight, minWeight, maxWeight, minFontSize, maxFontSize
            )
            let angle = rotations[index % rotations.size]
            let boxWidth = if (angle == 0.0) {
                chartTextWidth(word.text, fontSize)
            } else {
                fontSize
            }
            let boxHeight = if (angle == 0.0) {
                fontSize
            } else {
                chartTextWidth(word.text, fontSize)
            }
            if (cursorX > frame.plot.x && cursorX + boxWidth > frame.plot.right()) {
                cursorX = frame.plot.x
                cursorY += rowHeight + gap
                rowHeight = 0.0
            }
            if (cursorY + boxHeight > frame.plot.bottom()) {
                break
            }
            let color = if (word.color.isEmpty()) {
                config.theme.colorAt(index % config.theme.palette.size)
            } else {
                word.color
            }
            if (angle == 0.0) {
                kit.text(
                    cursorX, cursorY + boxHeight / 2.0, word.text,
                    size: fontSize,
                    color: color,
                    className: "word-cloud-word"
                )
            } else {
                let anchorX = cursorX + fontSize / 2.0
                kit.text(
                    anchorX, cursorY, word.text,
                    size: fontSize,
                    color: color,
                    className: "word-cloud-word word-cloud-rotated",
                    rotate: angle
                )
            }
            cursorX += boxWidth + gap
            rowHeight = maxFloat(rowHeight, boxHeight)
        }
        builder.toSvgString()
    }
}

/** 权重 → 字号：开方归一化映射到 [minSize, maxSize]。 */
internal func wordCloudFontSize(
    weight: Float64,
    minWeight: Float64,
    maxWeight: Float64,
    minSize: Float64,
    maxSize: Float64
): Float64 {
    if (maxWeight - minWeight <= 0.0) {
        return minSize
    }
    let ratio = (weight - minWeight) / (maxWeight - minWeight)
    let clamped = if (ratio < 0.0) { 0.0 } else if (ratio > 1.0) { 1.0 } else { ratio }
    minSize + (maxSize - minSize) * sqrt(clamped)
}

/** 按权重降序稳定排序。 */
internal func wordCloudOrder(words: ArrayList<WordCloudWord>): Array<WordCloudWord> {
    let sorted = ArrayList<WordCloudWord>()
    for (word in words) {
        sorted.add(word)
    }
    for (i in 1..sorted.size) {
        var j = i
        while (j > 0 && sorted[j].weight > sorted[j - 1].weight) {
            let temporary = sorted[j]
            sorted[j] = sorted[j - 1]
            sorted[j - 1] = temporary
            j--
        }
    }
    sorted.toArray()
}
