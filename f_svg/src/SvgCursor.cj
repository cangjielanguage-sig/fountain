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

private let SVG_CURSOR_KEYWORDS: Array<String> = [
    "auto", "default", "none", "context-menu", "help", "pointer", "progress", "wait",
    "cell", "crosshair", "text", "vertical-text", "alias", "copy", "move", "no-drop",
    "not-allowed", "grab", "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize",
    "s-resize", "se-resize", "sw-resize", "w-resize", "ew-resize", "ns-resize",
    "nesw-resize", "nwse-resize", "col-resize", "row-resize", "all-scroll", "zoom-in",
    "zoom-out"
]

/**
 * `cursor` 的计算值。
 *
 * M6 只做关键字白名单校验；`url(...)` 与未知值回退 `auto` 并 warning，
 * 不加载光标资源、不产生 UI。
 */
public struct SvgCursor <: ToString {
    public let name: String

    public init(name!: String = "auto") {
        this.name = name
    }

    /** 解析单个关键字；未知值回退 `auto`。 */
    public static func parse(text: String): SvgCursor {
        parse(text, ArrayList<String>())
    }

    /** 解析并写 warning；`url(...)` 与未知值都回退 `auto`。 */
    public static func parse(text: String, warnings: ArrayList<String>): SvgCursor {
        let trimmed = text.trimAscii()
        let lower = trimmed.toAsciiLower()
        if (lower.size == 0) {
            warnings.add("cursor 为空，已回退 auto")
            return SvgCursor(name: "auto")
        }
        if (lower.startsWith("url(")) {
            warnings.add("cursor 的 url() 资源不加载，已回退 auto：${trimmed}")
            return SvgCursor(name: "auto")
        }
        if (!isSvgCursorKeyword(lower)) {
            warnings.add("cursor 的值「${trimmed}」不受支持，已回退 auto")
            return SvgCursor(name: "auto")
        }
        SvgCursor(name: lower)
    }

    public func toString(): String {
        this.name
    }
}

private func isSvgCursorKeyword(name: String): Bool {
    for (keyword in SVG_CURSOR_KEYWORDS) {
        if (keyword == name) {
            return true
        }
    }
    false
}
