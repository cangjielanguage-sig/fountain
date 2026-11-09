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
package fountain::fprobe.collect.proc

import std.collection.ArrayList
import std.convert.*

/**
 * 按空白切分一行文本。
 *
 * `/proc` 与 `df -P` 都可能有连续空格；空字段直接丢弃，保持列序号稳定。
 */
func splitWhitespace(line: String): Array<String> {
    let result = ArrayList<String>()
    for (part in line.split(" ")) {
        let trimmed = part.trimAscii()
        if (!trimmed.isEmpty()) {
            result.add(trimmed)
        }
    }
    result.toArray()
}

/** 把 `tokens[start..]` 重新用单空格拼接，用于恢复带空格的挂载点。 */
func joinFrom(tokens: Array<String>, start: Int64): String {
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

/** 解析成功返回 Some；供各探针把「格式错误」统一收敛为 COLLECT 错误。 */
func tryInt64(token: String): ?Int64 {
    Int64.tryParse(token)
}

func tryFloat64(token: String): ?Float64 {
    Float64.tryParse(token)
}

/** 把百分比裁剪到 0..100，避免内核计数回绕或时钟回退产生越界值。 */
func clampPercent(value: Float64): Float64 {
    if (value < 0.0) {
        0.0
    } else if (value > 100.0) {
        100.0
    } else {
        value
    }
}

func nonNegativeDelta(current: Int64, previous: Int64): Int64 {
    let delta = current - previous
    if (delta < 0) {
        0
    } else {
        delta
    }
}
