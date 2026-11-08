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

import std.math.*
import std.convert.*
import fountain::f_base.*

private let SVG_NUMBER_TOLERANCE = 1e-6

/**
 * SVG 数值的规范字符串。
 *
 * - 非有限值抛 `InvalidValue`；
 * - `-0.0` 与 `|v| < 1e-6` 输出 `0`；
 * - 整数不带小数点，非整数最多 6 位小数且去掉末尾 `0`；
 * - 不使用科学计数法。
 */
public func formatSvgNumber(value: Float64): String {
    if (value.isNaN() || value.isInf()) {
        throw SvgException("SVG 数值必须是有限数，实际为 ${value}", kind: SvgErrorKind.InvalidValue)
    }
    if (value == 0.0 || abs(value) < SVG_NUMBER_TOLERANCE) {
        return "0"
    }
    // Float64.toString() 固定 6 位小数、不输出指数形式，直接裁剪即可。
    let text = value.toString()
    var end = text.size
    while (end > 0 && text[end - 1] == b'0') {
        end--
    }
    if (end > 0 && text[end - 1] == b'.') {
        end--
    }
    text[0..end]
}

/** 一个已扫描的 SG 数字：值、起始位置、结束位置（字节下标，结束位置不含）。 */
internal struct SvgNumberToken {
    let value: Float64
    let start: Int64
    let end: Int64

    init(value: Float64, start: Int64, end: Int64) {
        this.value = value
        this.start = start
        this.end = end
    }
}

internal func isSvgDigit(byte: Byte): Bool {
    byte >= b'0' && byte <= b'9'
}

internal func isSvgSpace(byte: Byte): Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
}

internal func isSvgAlpha(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z')
}

internal func skipSvgSpaces(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start
    while (i < bytes.size && isSvgSpace(bytes[i])) {
        i++
    }
    i
}

/**
 * 扫描一个 SVG 十进制数。
 *
 * 接受 `1`、`-1.5`、`.5`、`1.`、`1e3`、`1E-3`；指数部分不完整时（`1e`）只吃到
 * `e` 之前的数字，由调用方的后续校验报错。
 */
internal func scanSvgNumber(text: String, start: Int64): ?SvgNumberToken {
    let bytes = text.unsafeBytes()
    if (start >= bytes.size) {
        return None
    }
    let begin = start
    var i = start
    if (bytes[i] == b'+' || bytes[i] == b'-') {
        i++
    }
    var intDigits = 0
    while (i < bytes.size && isSvgDigit(bytes[i])) {
        i++
        intDigits++
    }
    var fracDigits = 0
    if (i < bytes.size && bytes[i] == b'.') {
        i++
        while (i < bytes.size && isSvgDigit(bytes[i])) {
            i++
            fracDigits++
        }
    }
    if (intDigits == 0 && fracDigits == 0) {
        return None
    }
    if (i < bytes.size && (bytes[i] == b'e' || bytes[i] == b'E')) {
        var j = i + 1
        if (j < bytes.size && (bytes[j] == b'+' || bytes[j] == b'-')) {
            j++
        }
        var expDigits = 0
        while (j < bytes.size && isSvgDigit(bytes[j])) {
            j++
            expDigits++
        }
        if (expDigits > 0) {
            i = j
        }
    }
    let raw = normalizeSvgNumber(text[begin..i])
    var parsed = 0.0
    try {
        parsed = Float64.parse(raw)
    } catch (_: Exception) {
        return None
    }
    SvgNumberToken(parsed, begin, i)
}

/** 把 `+.5` / `1.` 之类的写法补成 `Float64.parse` 接受的形式。 */
private func normalizeSvgNumber(raw: String): String {
    var text = raw
    if (text.size > 0 && text[0] == b'+') {
        text = text[1..]
    }
    if (text.size > 0 && text[0] == b'.') {
        text = "0" + text
    } else if (text.size > 1 && text[0] == b'-' && text[1] == b'.') {
        text = "-0" + text[1..]
    }
    if (text.size > 0 && text[text.size - 1] == b'.') {
        text = text + "0"
    }
    text
}

/** 校验有限性；值类型与路径解析共用。 */
internal func requireFinite(value: Float64, what: String): Float64 {
    if (value.isNaN() || value.isInf()) {
        throw SvgException("${what}必须是有限数，实际为 ${value}", kind: SvgErrorKind.InvalidValue)
    }
    value
}
