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
package fountain::f_xml

import std.collection.ArrayList

/**
 * XML 1.0（第 5 版）的产生式判定。
 *
 * 只放纯函数：`Char` / `NameStartChar` / `NameChar` / `S`。这些判定在词法、DTD、生成器
 * 三处共用，集中一处避免漂移。
 */
internal class XmlChars {
    /** `Char ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]` */
    static func isXmlChar(cp: Int64): Bool {
        cp == 0x9 || cp == 0xA || cp == 0xD ||
            (cp >= 0x20 && cp <= 0xD7FF) ||
            (cp >= 0xE000 && cp <= 0xFFFD) ||
            (cp >= 0x10000 && cp <= 0x10FFFF)
    }

    static func isWhitespace(r: Rune): Bool {
        r == r' ' || r == r'\t' || r == r'\n' || r == r'\r'
    }

    /** `NameStartChar`（含 `:`，命名空间层再单独限制）。 */
    static func isNameStartChar(cp: Int64): Bool {
        cp == 0x3A || cp == 0x5F ||
            (cp >= 0x41 && cp <= 0x5A) ||
            (cp >= 0x61 && cp <= 0x7A) ||
            (cp >= 0xC0 && cp <= 0xD6) ||
            (cp >= 0xD8 && cp <= 0xF6) ||
            (cp >= 0xF8 && cp <= 0x2FF) ||
            (cp >= 0x370 && cp <= 0x37D) ||
            (cp >= 0x37F && cp <= 0x1FFF) ||
            (cp >= 0x200C && cp <= 0x200D) ||
            (cp >= 0x2070 && cp <= 0x218F) ||
            (cp >= 0x2C00 && cp <= 0x2FEF) ||
            (cp >= 0x3001 && cp <= 0xD7FF) ||
            (cp >= 0xF900 && cp <= 0xFDCF) ||
            (cp >= 0xFDF0 && cp <= 0xFFFD) ||
            (cp >= 0x10000 && cp <= 0xEFFFF)
    }

    static func isNameChar(cp: Int64): Bool {
        isNameStartChar(cp) ||
            cp == 0x2D || cp == 0x2E || cp == 0xB7 ||
            (cp >= 0x30 && cp <= 0x39) ||
            (cp >= 0x300 && cp <= 0x36F) ||
            (cp >= 0x203F && cp <= 0x2040)
    }

    /** 十进制数字（`&#DDD;`）。 */
    static func isDigit(r: Rune): Bool {
        r >= r'0' && r <= r'9'
    }

    /** 十六进制数字（`&#xHHH;`）。 */
    static func isHexDigit(r: Rune): Bool {
        (r >= r'0' && r <= r'9') || (r >= r'a' && r <= r'f') || (r >= r'A' && r <= r'F')
    }

    static func hexValue(r: Rune): Int64 {
        if (r >= r'0' && r <= r'9') {
            Int64(r.position() - r'0'.position())
        } else if (r >= r'a' && r <= r'f') {
            Int64(r.position() - r'a'.position()) + 10
        } else {
            Int64(r.position() - r'A'.position()) + 10
        }
    }

    /** 码点的十六进制文本（错误消息用），不带 `0x`。 */
    static func hex(cp: Int64): String {
        const digits = "0123456789ABCDEF"
        if (cp == 0) {
            return "0"
        }
        var value = cp
        var out = ""
        while (value > 0) {
            let d = Int64(value % 16)
            out = digits[d..d + 1] + out
            value = value / 16
        }
        out
    }
}

/** 把字符串拆成 rune 数组（多处需要按下标访问）。 */
internal func runesOf(text: String): Array<Rune> {
    let out = ArrayList<Rune>()
    for (r in text.runes()) {
        out.add(r)
    }
    out.toArray()
}
