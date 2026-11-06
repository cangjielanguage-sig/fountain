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

import fountain::f_base.*

/** `calc()` 括号嵌套上限。 */
internal let CSS_CALC_MAX_DEPTH: Int64 = 16

/** 计算值的单位族：纯数字 / 绝对长度（px、em 已换算）/ 百分比。 */
private enum CssCalcUnit <: Equatable<CssCalcUnit> {
    | Number
    | Absolute
    | Percent

    public operator func ==(that: CssCalcUnit): Bool {
        match ((this, that)) {
            case (Number, Number) => true
            case (Absolute, Absolute) => true
            case (Percent, Percent) => true
            case _ => false
        }
    }
}

private class CssCalcValue {
    let value: Float64
    let unit: CssCalcUnit

    init(value: Float64, unit: CssCalcUnit) {
        this.value = value
        this.unit = unit
    }
}

/**
 * 求值 `calc()` 表达式，返回可交给 `SvgLength` 解析的文本。
 *
 * 只支持数字、`px` / `%` / `em`、`+` `-` `*` `/` 与括号；`*` / `/` 至少一侧为数字，
 * 百分比与绝对长度不得混用。失败返回 `None`。
 */
internal func evaluateCssCalc(expression: String, fontSizePx: Float64): ?String {
    let parser = CssCalcParser(expression, fontSizePx)
    match (parser.parseAll()) {
        case Some(result) => Some(formatCssCalcValue(result))
        case None => None
    }
}

private func formatCssCalcValue(value: CssCalcValue): String {
    match (value.unit) {
        case Number => formatSvgNumber(value.value)
        case Absolute => formatSvgNumber(value.value) + "px"
        case Percent => formatSvgNumber(value.value) + "%"
    }
}

private class CssCalcParser {
    private let text: String
    private let bytes: Array<Byte>
    private let fontSizePx: Float64
    private var i: Int64 = 0
    private var depth: Int64 = 0

    init(text: String, fontSizePx: Float64) {
        this.text = text
        this.bytes = text.unsafeBytes()
        this.fontSizePx = fontSizePx
    }

    func parseAll(): ?CssCalcValue {
        let value = this.parseExpression()
        match (value) {
            case Some(result) =>
                this.skipSpaces()
                if (this.i != this.bytes.size) {
                    return None
                }
                Some(result)
            case None => None
        }
    }

    private func skipSpaces(): Unit {
        while (this.i < this.bytes.size && isCssSpace(this.bytes[this.i])) {
            this.i++
        }
    }

    private func parseExpression(): ?CssCalcValue {
        var left = match (this.parseTerm()) {
            case Some(value) => value
            case None => return None
        }
        while (true) {
            this.skipSpaces()
            if (this.i >= this.bytes.size) {
                return Some(left)
            }
            let marker = this.bytes[this.i]
            if (marker != b'+' && marker != b'-') {
                return Some(left)
            }
            this.i++
            let right = match (this.parseTerm()) {
                case Some(value) => value
                case None => return None
            }
            left = match (combineCssCalcAdd(left, right, marker == b'+')) {
                case Some(value) => value
                case None => return None
            }
        }
        Some(left)
    }

    private func parseTerm(): ?CssCalcValue {
        var left = match (this.parseUnary()) {
            case Some(value) => value
            case None => return None
        }
        while (true) {
            this.skipSpaces()
            if (this.i >= this.bytes.size) {
                return Some(left)
            }
            let marker = this.bytes[this.i]
            if (marker != b'*' && marker != b'/') {
                return Some(left)
            }
            this.i++
            let right = match (this.parseUnary()) {
                case Some(value) => value
                case None => return None
            }
            left = match (combineCssCalcMul(left, right, marker == b'*')) {
                case Some(value) => value
                case None => return None
            }
        }
        Some(left)
    }

    private func parseUnary(): ?CssCalcValue {
        this.skipSpaces()
        if (this.i < this.bytes.size && this.bytes[this.i] == b'-') {
            this.i++
            return match (this.parseUnary()) {
                case Some(value) => Some(CssCalcValue(-value.value, value.unit))
                case None => None
            }
        }
        if (this.i < this.bytes.size && this.bytes[this.i] == b'+') {
            this.i++
            return this.parseUnary()
        }
        this.parsePrimary()
    }

    private func parsePrimary(): ?CssCalcValue {
        this.skipSpaces()
        if (this.i >= this.bytes.size) {
            return None
        }
        if (this.bytes[this.i] == b'(') {
            if (this.depth >= CSS_CALC_MAX_DEPTH) {
                return None
            }
            this.depth++
            this.i++
            let inner = match (this.parseExpression()) {
                case Some(value) => value
                case None => return None
            }
            this.skipSpaces()
            if (this.i >= this.bytes.size || this.bytes[this.i] != b')') {
                return None
            }
            this.i++
            this.depth--
            return Some(inner)
        }
        let start = this.i
        var sawDigit = false
        while (this.i < this.bytes.size && (isCssDigit(this.bytes[this.i]) || this.bytes[this.i] == b'.')) {
            if (isCssDigit(this.bytes[this.i])) {
                sawDigit = true
            }
            this.i++
        }
        if (!sawDigit) {
            return None
        }
        let numberText = this.text[start..this.i]
        let value = match (tryParseSvgFloat(numberText)) {
            case Some(parsed) => parsed
            case None => return None
        }
        if (this.i < this.bytes.size && isCssAlpha(this.bytes[this.i])) {
            let unitStart = this.i
            while (this.i < this.bytes.size && isCssAlpha(this.bytes[this.i])) {
                this.i++
            }
            let unit = this.text[unitStart..this.i].toAsciiLower()
            return match (unit) {
                case "px" => Some(CssCalcValue(value, CssCalcUnit.Absolute))
                case "em" => Some(CssCalcValue(value * this.fontSizePx, CssCalcUnit.Absolute))
                case _ => None
            }
        }
        if (this.i < this.bytes.size && this.bytes[this.i] == b'%') {
            this.i++
            return Some(CssCalcValue(value, CssCalcUnit.Percent))
        }
        Some(CssCalcValue(value, CssCalcUnit.Number))
    }
}

private func combineCssCalcAdd(left: CssCalcValue, right: CssCalcValue, add: Bool): ?CssCalcValue {
    if (left.unit != right.unit) {
        return None
    }
    let value = if (add) { left.value + right.value } else { left.value - right.value }
    if (!isFiniteSvgNumber(value)) {
        return None
    }
    CssCalcValue(value, left.unit)
}

private func combineCssCalcMul(left: CssCalcValue, right: CssCalcValue, multiply: Bool): ?CssCalcValue {
    if (multiply) {
        if (left.unit == CssCalcUnit.Number) {
            return CssCalcValue(left.value * right.value, right.unit)
        }
        if (right.unit == CssCalcUnit.Number) {
            return CssCalcValue(left.value * right.value, left.unit)
        }
        return None
    }
    if (right.unit != CssCalcUnit.Number || right.value == 0.0) {
        return None
    }
    CssCalcValue(left.value / right.value, left.unit)
}
