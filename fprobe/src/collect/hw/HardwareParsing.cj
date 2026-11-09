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
package fountain::fprobe.collect.hw

import std.collection.ArrayList
import std.convert.*

/** 按空白切分一行；空字段丢弃，供硬件命令输出解析共用。 */
func splitTokens(line: String): Array<String> {
    let result = ArrayList<String>()
    for (part in line.split(" ")) {
        let trimmed = part.trimAscii()
        if (!trimmed.isEmpty()) {
            result.add(trimmed)
        }
    }
    result.toArray()
}

/** 把 `tokens[start..]` 用单空格拼回，用于恢复带空格的单位或描述。 */
func joinTokens(tokens: Array<String>, start: Int64): String {
    var result = ""
    var index = start
    while (index < tokens.size) {
        if (!result.isEmpty()) {
            result += " "
        }
        result += tokens[index]
        index += 1
    }
    result
}

func tryFloat(token: String): ?Float64 {
    Float64.tryParse(token)
}

/** 参数中任何空白都会破坏「参数数组直传」的边界。 */
func hasWhitespace(value: String): Bool {
    value.contains(' ') || value.contains('\t') || value.contains('\n') || value.contains('\r')
}

/** 拒绝会改变 shell 语义的字符，即使当前实现从不经过 shell。 */
func hasShellMeta(value: String): Bool {
    value.contains('`') || value.contains('$') || value.contains(';') || value.contains('&') ||
        value.contains('|') || value.contains('<') || value.contains('>') || value.contains('\\') ||
        value.contains('\'') || value.contains('"') || value.contains('(') || value.contains(')')
}

func stripQuotes(value: String): String {
    let text = value.trimAscii()
    if (text.size >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        return text[1..text.size - 1]
    }
    if (text.size >= 2 && text.startsWith("'") && text.endsWith("'")) {
        return text[1..text.size - 1]
    }
    text
}
