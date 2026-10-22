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
package fountain::f_mq.base

import std.unicode.*

/**
 * 组名/tags/主题共用的字符集判定。
 *
 * 按 `Rune`（码点）而不是字节判断：`String` 的迭代单位是字节，
 * 只看 `<= 0x20` 会漏掉 DEL、NBSP、表意空格、行分隔符等 Unicode 空白（R1-G12）。
 */
internal class MQChars {
    /** 控制字符（C0 `0x00-0x1F`、DEL `0x7F`、C1 `0x80-0x9F`）或 Unicode 空白字符。 */
    static func isBlankOrControl(rune: Rune): Bool {
        let code = rune.position()
        if (code <= 0x1F || (code >= 0x7F && code <= 0x9F)) {
            return true
        }
        rune.isWhiteSpace()
    }

    /** 名称类字段（组名、tag、主题段）是否含非法字符。 */
    static func containsBlankOrControl(text: String): Bool {
        for (rune in text.runes()) {
            if (isBlankOrControl(rune)) {
                return true
            }
        }
        false
    }
}
