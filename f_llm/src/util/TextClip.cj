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
package fountain::f_llm.util

/**
 * 文本裁剪：按**字符**（rune）计数，UTF-8 安全的截断（不在字符内部切断）。
 *
 * 与按字节的 `String[0..n]` 不同：中文 3 字节/字，按字节切几乎必然落在字符中间并抛异常。
 */
public class TextClip {
    private init() {
    }

    /**
     * 取前 `maxChars` 个字符；超长时补省略号。
     *
     * @param maxChars 字符数上限，`<= 0` 时返回空串
     */
    public static func clip(text: String, maxChars: Int64): String {
        if (maxChars <= 0) {
            return ''
        }
        let builder = StringBuilder()
        var count: Int64 = 0
        var truncated = false
        for (rune in text.runes()) {
            if (count >= maxChars) {
                truncated = true
                break
            }
            builder.append(rune)
            count++
        }
        if (truncated) {
            builder.append('…')
        }
        builder.toString()
    }
}
