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
package fountain::f_svg

import std.collection.*
import fountain::f_base.*

/** `var()` 嵌套上限。 */
internal let CSS_VAR_MAX_DEPTH: Int64 = 8

/** 文本中是否含 `var(`（ASCII 大小写不敏感）。 */
internal func containsCssVariable(text: String): Bool {
    findCssVarCall(text, 0) >= 0
}

/**
 * 展开属性值中的 `var()`。
 *
 * `lookup` 返回自定义属性的原文（可继续包含 `var()`）；`visited` 用于循环检测，
 * `depth` 为已展开层数。任一引用无法解析时整体返回 `None`。
 */
internal func expandCssVariables(
    value: String,
    lookup: (String) -> ?String,
    visited: Array<String>,
    depth: Int64
): ?String {
    let out = StringBuilder()
    var cursor = 0
    while (true) {
        let at = findCssVarCall(value, cursor)
        if (at < 0) {
            out.append(value[cursor..])
            break
        }
        out.append(value[cursor..at])
        let bytes = value.unsafeBytes()
        let open = at + 3
        let close = findCssClosingParen(bytes, open)
        if (close < 0) {
            return None
        }
        let inner = value[open + 1..close]
        let arguments = splitCssVarArguments(inner)
        let name = arguments[0].trimAscii()
        if (!name.startsWith("--") || name.size < 3) {
            return None
        }
        if (depth >= CSS_VAR_MAX_DEPTH) {
            return None
        }
        match (lookup(name)) {
            case Some(raw) =>
                if (cssVarVisited(visited, name)) {
                    return None
                }
                let expandedRaw = match (
                    expandCssVariables(raw, lookup, cssVarPush(visited, name), depth + 1)) {
                    case Some(text) => text
                    case None => return None
                }
                out.append(expandedRaw)
            case None =>
                match (arguments[1]) {
                    case Some(fallback) =>
                        if (fallback.trimAscii().size == 0) {
                            return None
                        }
                        let expandedFallback = match (
                            expandCssVariables(fallback.trimAscii(), lookup, visited, depth + 1)) {
                            case Some(text) => text
                            case None => return None
                        }
                        out.append(expandedFallback)
                    case None => return None
                }
        }
        cursor = close + 1
    }
    Some(out.toString())
}

/** 从 `from` 开始找 `var(` 的起始下标；找不到返回 -1。 */
private func findCssVarCall(text: String, from: Int64): Int64 {
    let bytes = text.unsafeBytes()
    var i = from
    while (i + 3 < bytes.size) {
        if (isCssVarLetter(bytes[i]) && isCssVarLetter(bytes[i + 1]) && isCssVarLetter(bytes[i + 2]) &&
            bytes[i + 3] == b'(') {
            if (text[i..i + 4].toAsciiLower() == "var(") {
                if (i == 0 || !isCssIdentByte(bytes[i - 1])) {
                    return i
                }
            }
        }
        i++
    }
    -1
}

private func isCssVarLetter(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
}

/** 按首个顶层逗号拆分 `var()` 参数：`(名称, ?fallback)`。 */
private func splitCssVarArguments(inner: String): (String, ?String) {
    let bytes = inner.unsafeBytes()
    var depth = 0
    for (index in 0..bytes.size) {
        match (bytes[index]) {
            case b'(' => depth++
            case b')' => if (depth > 0) {
                depth--
            }
            case b',' => if (depth == 0) {
                return (inner[0..index], Some(inner[index + 1..]))
            }
            case _ => ()
        }
    }
    (inner, None)
}

private func cssVarVisited(visited: Array<String>, name: String): Bool {
    for (item in visited) {
        if (item == name) {
            return true
        }
    }
    false
}

private func cssVarPush(visited: Array<String>, name: String): Array<String> {
    let next = ArrayList<String>()
    for (item in visited) {
        next.add(item)
    }
    next.add(name)
    next.toArray()
}
