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
package fountain::f_excel

import std.collection.ArrayList
import fountain::f_base.StringGenerator

/** 富文本分段的字体（`<rPr>`）；没写的字段是 `None`，不猜默认值。 */
public struct RunFont <: ToString {
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let size: ?Float64
    public let color: ?String
    public let name: ?String

    public init(
        bold!: Bool = false,
        italic!: Bool = false,
        underline!: Bool = false,
        size!: ?Float64 = None,
        color!: ?String = None,
        name!: ?String = None
    ) {
        this.bold = bold
        this.italic = italic
        this.underline = underline
        this.size = size
        this.color = color
        this.name = name
    }

    public func toString(): String {
        "RunFont(b=${this.bold}, i=${this.italic}, u=${this.underline})"
    }
}

/** 一段连续文本及其字体。 */
public struct TextRun <: ToString {
    public let text: String
    public let font: ?RunFont

    public init(text: String, font!: ?RunFont = None) {
        this.text = text
        this.font = font
    }

    public func toString(): String {
        match (this.font) {
            case Some(value) => "TextRun(${this.text}, ${value})"
            case None => "TextRun(${this.text})"
        }
    }
}

/**
 * 富文本（`sharedStrings` 的 `<si>` 里多个 `<r>`）。
 *
 * 单元格的 `CellValue` 仍是**平坦化**的 `Text`，`RichText` 是并行的样式信息；
 * 写侧 M2 仍写 `inlineStr`，富文本样式不落盘（设计 M2-d 口径）。
 */
public struct RichText <: ToString {
    public let runs: ArrayList<TextRun>

    public init(runs: ArrayList<TextRun>) {
        this.runs = runs
    }

    /** 拼接后的纯文本。 */
    public func text(): String {
        let out = StringGenerator()
        for (run in this.runs) {
            out.append<String>(run.text)
        }
        out.toString()
    }

    public func toString(): String {
        "RichText(${this.runs.size} runs)"
    }
}
