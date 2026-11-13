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
package fountain::f_chart.tui

import std.collection.ArrayList

/** 单个字符在终端中的显示宽度：CJK/全角按 2 列，其余按 1 列。 */
internal func tuiRuneWidth(rune: Rune): Int64 {
    if (rune.position() >= 0x2E80) {
        2
    } else {
        1
    }
}

/** 文本的终端显示宽度。 */
internal func tuiDisplayWidth(text: String): Int64 {
    var width = 0
    for (rune in text.runes()) {
        width += tuiRuneWidth(rune)
    }
    width
}

/** 按显示宽度截断；发生截断时以 `…` 结尾。 */
internal func tuiTruncate(text: String, width: Int64): String {
    if (width <= 0) {
        return ""
    }
    if (tuiDisplayWidth(text) <= width) {
        return text
    }
    if (width == 1) {
        return "…"
    }
    let limit = width - 1
    let builder = StringBuilder()
    var used = 0
    for (rune in text.runes()) {
        let runeWidth = tuiRuneWidth(rune)
        if (used + runeWidth > limit) {
            break
        }
        builder.append(rune.toString())
        used += runeWidth
    }
    builder.append("…")
    builder.toString()
}

/** 按显示宽度在右侧补空格。 */
internal func tuiPadRight(text: String, width: Int64): String {
    let current = tuiDisplayWidth(text)
    if (current >= width) {
        return text
    }
    let builder = StringBuilder()
    builder.append(text)
    var index = current
    while (index < width) {
        builder.append(" ")
        index++
    }
    builder.toString()
}

/** 按显示宽度在左侧补空格。 */
internal func tuiPadLeft(text: String, width: Int64): String {
    let current = tuiDisplayWidth(text)
    if (current >= width) {
        return text
    }
    let builder = StringBuilder()
    var index = current
    while (index < width) {
        builder.append(" ")
        index++
    }
    builder.append(text)
    builder.toString()
}
