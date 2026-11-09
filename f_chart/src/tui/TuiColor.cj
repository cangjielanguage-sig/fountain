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
import fountain::f_chart.*
import fountain::f_svg.SvgColor

/** ANSI 复位序列。 */
internal func tuiAnsiReset(): String {
    "\u{1B}[0m"
}

/** 把 CSS 颜色转换为 ANSI 24 位前景色；非法颜色抛 `InvalidValue`。 */
internal func tuiAnsiForeground(color: String): String {
    try {
        let parsed = SvgColor.parse(color)
        "\u{1B}[38;2;${parsed.red};${parsed.green};${parsed.blue}m"
    } catch (_: Exception) {
        throw chartInvalidValue("color", "非法的颜色 ${color}")
    }
}

/** 去掉字符串中的 ANSI CSI 序列，便于测试断言纯文本。 */
internal func tuiStripAnsi(text: String): String {
    let bytes = text.toArray()
    let builder = StringBuilder()
    var index = 0
    while (index < bytes.size) {
        if (bytes[index] == 0x1B && index + 1 < bytes.size && bytes[index + 1] == b'[') {
            index += 2
            while (index < bytes.size && bytes[index] != b'm') {
                index++
            }
            if (index < bytes.size) {
                index++
            }
        } else {
            let start = index
            while (index < bytes.size && bytes[index] != 0x1B) {
                index++
            }
            builder.append(String.fromUtf8(bytes[start..index]))
        }
    }
    builder.toString()
}

/** 去掉 ANSI 后按行拆分，并去掉末尾换行产生的空行。 */
internal func tuiPlainLines(svg: String): Array<String> {
    let lines = tuiStripAnsi(svg).split("\n")
    let result = ArrayList<String>()
    for (line in lines) {
        result.add(line)
    }
    if (!result.isEmpty() && result[result.size - 1].isEmpty()) {
        result.remove(at: result.size - 1)
    }
    result.toArray()
}
