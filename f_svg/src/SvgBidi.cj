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

/** 文本方向。 */
public enum SvgDirection <: Equatable<SvgDirection> & ToString {
    | Ltr
    | Rtl

    public operator func ==(that: SvgDirection): Bool {
        match ((this, that)) {
            case (Ltr, Ltr) => true
            case (Rtl, Rtl) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Ltr => "ltr"
            case Rtl => "rtl"
        }
    }

    public static func fromName(name: String): ?SvgDirection {
        match (name.trimAscii().toAsciiLower()) {
            case "ltr" => Some(Ltr)
            case "rtl" => Some(Rtl)
            case _ => None
        }
    }
}

/** `unicode-bidi`。 */
public enum SvgUnicodeBidi <: Equatable<SvgUnicodeBidi> & ToString {
    | Normal
    | Embed
    | BidiOverride

    public operator func ==(that: SvgUnicodeBidi): Bool {
        match ((this, that)) {
            case (Normal, Normal) => true
            case (Embed, Embed) => true
            case (BidiOverride, BidiOverride) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Normal => "normal"
            case Embed => "embed"
            case BidiOverride => "bidi-override"
        }
    }

    public static func fromName(name: String): ?SvgUnicodeBidi {
        match (name.trimAscii().toAsciiLower()) {
            case "normal" => Some(Normal)
            case "embed" => Some(Embed)
            case "bidi-override" => Some(BidiOverride)
            case _ => None
        }
    }
}

/** `font-kerning` 的取值。 */
public enum SvgFontKerning <: Equatable<SvgFontKerning> & ToString {
    | Auto
    | Normal
    | None

    public operator func ==(that: SvgFontKerning): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Normal, Normal) => true
            case (None, None) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Normal => "normal"
            case None => "none"
        }
    }

    public static func fromName(name: String): ?SvgFontKerning {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "normal" => Some(Normal)
            case "none" => Some(SvgFontKerning.None)
            case _ => Option<SvgFontKerning>.None
        }
    }
}

/** UAX#9 子集覆盖的方向类别。 */
public enum SvgBidiClass <: Equatable<SvgBidiClass> & ToString {
    | L
    | R
    | AL
    | EN
    | AN
    | WS
    | ON
    | B

    public operator func ==(that: SvgBidiClass): Bool {
        match ((this, that)) {
            case (L, L) => true
            case (R, R) => true
            case (AL, AL) => true
            case (EN, EN) => true
            case (AN, AN) => true
            case (WS, WS) => true
            case (ON, ON) => true
            case (B, B) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case L => "L"
            case R => "R"
            case AL => "AL"
            case EN => "EN"
            case AN => "AN"
            case WS => "WS"
            case ON => "ON"
            case B => "B"
        }
    }
}

/** 字符方向类别；未覆盖字符按 `L` 处理。 */
public func svgBidiClass(codePoint: Int64): SvgBidiClass {
    if (codePoint == 10 || codePoint == 13 || codePoint == 0x2029) {
        return SvgBidiClass.B
    }
    if (codePoint == 32 || codePoint == 9 || codePoint == 0x00A0 || codePoint == 0x2000 ||
        codePoint == 0x2001 || codePoint == 0x2002 || codePoint == 0x2003) {
        return SvgBidiClass.WS
    }
    if (codePoint >= 0x0660 && codePoint <= 0x0669) {
        return SvgBidiClass.AN
    }
    if (codePoint >= 0x06F0 && codePoint <= 0x06F9) {
        return SvgBidiClass.AN
    }
    if ((codePoint >= 0x0590 && codePoint <= 0x05FF) || (codePoint >= 0xFB1D && codePoint <= 0xFB4F) ||
        (codePoint >= 0x07C0 && codePoint <= 0x089F) || (codePoint >= 0xFB50 && codePoint <= 0xFDFF) ||
        (codePoint >= 0xFE70 && codePoint <= 0xFEFF) || (codePoint >= 0x10800 && codePoint <= 0x10FFF)) {
        if (codePoint >= 0x0600 && codePoint <= 0x06FF) {
            return SvgBidiClass.AL
        }
        return SvgBidiClass.R
    }
    if (codePoint >= 0x0600 && codePoint <= 0x06FF) {
        return SvgBidiClass.AL
    }
    if (codePoint >= 0x30 && codePoint <= 0x39) {
        return SvgBidiClass.EN
    }
    if (codePoint >= 0x41 && codePoint <= 0x5A) {
        return SvgBidiClass.L
    }
    if (codePoint >= 0x61 && codePoint <= 0x7A) {
        return SvgBidiClass.L
    }
    if (codePoint >= 0xC0 && codePoint <= 0x24F) {
        return SvgBidiClass.L
    }
    if (codePoint >= 0x370 && codePoint <= 0x3FF) {
        return SvgBidiClass.L
    }
    if (codePoint >= 0x400 && codePoint <= 0x4FF) {
        return SvgBidiClass.L
    }
    match (codePoint) {
        case 0x2B | 0x2D | 0x2F | 0x3A | 0x2C | 0x2E | 0x28 | 0x29 | 0x5B | 0x5D | 0x7B | 0x7D |
            0x3C | 0x3E | 0x22 | 0x27 | 0x21 | 0x3F => SvgBidiClass.ON
        case _ => SvgBidiClass.L
    }
}

/** 单层括号镜像映射；其他字符原样返回。 */
public func svgMirrorBidiCodePoint(codePoint: Int64): Int64 {
    match (codePoint) {
        case 0x28 => 0x29
        case 0x29 => 0x28
        case 0x5B => 0x5D
        case 0x5D => 0x5B
        case 0x7B => 0x7D
        case 0x7D => 0x7B
        case 0x3C => 0x3E
        case 0x3E => 0x3C
        case _ => codePoint
    }
}

/** 计算每个字符的嵌入层级（UAX#9 弱 / 中性 / 隐式子集）。 */
internal func svgBidiLevels(codePoints: Array<Int64>, paragraphRtl: Bool): Array<Int64> {
    let size = codePoints.size
    let base: Int64 = if (paragraphRtl) { 1 } else { 0 }
    let kinds = ArrayList<SvgBidiClass>()
    for (codePoint in codePoints) {
        kinds.add(svgBidiClass(codePoint))
    }
    // W3: AL 视为 R；W7: EN 前一个强类型为 L 时视为 L。
    var lastStrong = if (paragraphRtl) { SvgBidiClass.R } else { SvgBidiClass.L }
    for (index in 0..size) {
        if (kinds[index] == SvgBidiClass.AL) {
            kinds[index] = SvgBidiClass.R
        }
        if (kinds[index] == SvgBidiClass.EN && lastStrong == SvgBidiClass.L) {
            kinds[index] = SvgBidiClass.L
        }
        if (kinds[index] == SvgBidiClass.R || kinds[index] == SvgBidiClass.L) {
            lastStrong = kinds[index]
        }
    }
    // N1/N2：中性字符取两侧强类型，缺省取段落方向。
    var index: Int64 = 0
    while (index < size) {
        if (kinds[index] == SvgBidiClass.WS || kinds[index] == SvgBidiClass.ON) {
            let start = index
            while (index < size && (kinds[index] == SvgBidiClass.WS || kinds[index] == SvgBidiClass.ON)) {
                index++
            }
            let before: SvgBidiClass = if (start == 0) {
                if (paragraphRtl) { SvgBidiClass.R } else { SvgBidiClass.L }
            } else {
                strongBidiClass(kinds[start - 1], paragraphRtl)
            }
            let after: SvgBidiClass = if (index >= size) {
                if (paragraphRtl) { SvgBidiClass.R } else { SvgBidiClass.L }
            } else {
                strongBidiClass(kinds[index], paragraphRtl)
            }
            let resolved = if (before == after) {
                before
            } else if (paragraphRtl) {
                SvgBidiClass.R
            } else {
                SvgBidiClass.L
            }
            for (position in start..index) {
                kinds[position] = resolved
            }
        } else {
            index++
        }
    }
    // I1/I2：按基础层级推导最终层级。
    let levels = ArrayList<Int64>()
    for (kind in kinds) {
        var level = base
        if (base % 2 == 0) {
            if (kind == SvgBidiClass.R) {
                level = base + 1
            } else if (kind == SvgBidiClass.AN || kind == SvgBidiClass.EN) {
                level = base + 2
            }
        } else {
            if (kind == SvgBidiClass.L || kind == SvgBidiClass.AN || kind == SvgBidiClass.EN) {
                level = base + 1
            }
        }
        levels.add(level)
    }
    levels.toArray()
}

private func strongBidiClass(kind: SvgBidiClass, paragraphRtl: Bool): SvgBidiClass {
    if (kind == SvgBidiClass.R || kind == SvgBidiClass.AL) {
        return SvgBidiClass.R
    }
    if (kind == SvgBidiClass.L) {
        return SvgBidiClass.L
    }
    if (paragraphRtl) {
        SvgBidiClass.R
    } else {
        SvgBidiClass.L
    }
}

/** 逻辑下标 → 视觉顺序（L2 反转）。 */
internal func svgBidiVisualOrder(levels: Array<Int64>): Array<Int64> {
    let order = ArrayList<Int64>()
    for (index in 0..levels.size) {
        order.add(index)
    }
    if (levels.size == 0) {
        return order.toArray()
    }
    var highest = levels[0]
    var lowestOdd = Int64.Max
    for (level in levels) {
        if (level > highest) {
            highest = level
        }
        if (level % 2 != 0 && level < lowestOdd) {
            lowestOdd = level
        }
    }
    if (lowestOdd == Int64.Max) {
        return order.toArray()
    }
    var level = highest
    while (level >= lowestOdd) {
        var index: Int64 = 0
        while (index < levels.size) {
            if (levels[index] >= level) {
                let start = index
                while (index < levels.size && levels[index] >= level) {
                    index++
                }
                reverseBidiRange(order, start, index - 1)
            } else {
                index++
            }
        }
        level--
    }
    order.toArray()
}

private func reverseBidiRange(order: ArrayList<Int64>, start: Int64, end: Int64): Unit {
    var left = start
    var right = end
    while (left < right) {
        let temporary = order[left]
        order[left] = order[right]
        order[right] = temporary
        left++
        right--
    }
}

