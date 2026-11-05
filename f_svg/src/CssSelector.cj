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

/** 选择器组合符。 */
public enum CssCombinator <: Equatable<CssCombinator> & ToString {
    | Descendant
    | Child

    public operator func ==(that: CssCombinator): Bool {
        match ((this, that)) {
            case (Descendant, Descendant) => true
            case (Child, Child) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Descendant => "Descendant"
            case Child => "Child"
        }
    }
}

/** 复合选择器的一个简单选择器部分。`typeName == None` 表示 `*` 或缺省。 */
public struct CssSelectorPart <: ToString {
    public let typeName: ?String
    public let id: ?String
    public let classes: Array<String>

    init(typeName: ?String, id: ?String, classes: Array<String>) {
        this.typeName = typeName
        this.id = id
        this.classes = classes
    }

    public func toString(): String {
        let out = StringBuilder()
        match (this.typeName) {
            case Some(name) => out.append(name)
            case None => out.append("*")
        }
        match (this.id) {
            case Some(value) =>
                out.append("#")
                out.append(value)
            case None => ()
        }
        for (className in this.classes) {
            out.append(".")
            out.append(className)
        }
        out.toString()
    }
}

/** 特异性三元组 `(id, class, type)`。 */
public struct CssSpecificity <: Equatable<CssSpecificity> & ToString {
    public let ids: Int64
    public let classes: Int64
    public let types: Int64

    public init(ids: Int64, classes: Int64, types: Int64) {
        this.ids = ids
        this.classes = classes
        this.types = types
    }

    public static let zero = CssSpecificity(0, 0, 0)

    public func plus(that: CssSpecificity): CssSpecificity {
        CssSpecificity(this.ids + that.ids, this.classes + that.classes, this.types + that.types)
    }

    /** 字典序比较：返回 -1 / 0 / 1。 */
    public func compareTo(that: CssSpecificity): Int64 {
        if (this.ids != that.ids) {
            return if (this.ids < that.ids) { -1 } else { 1 }
        }
        if (this.classes != that.classes) {
            return if (this.classes < that.classes) { -1 } else { 1 }
        }
        if (this.types != that.types) {
            return if (this.types < that.types) { -1 } else { 1 }
        }
        0
    }

    public func toString(): String {
        "(${this.ids},${this.classes},${this.types})"
    }

    public operator func ==(that: CssSpecificity): Bool {
        this.ids == that.ids && this.classes == that.classes && this.types == that.types
    }
}

/**
 * 一个选择器：`g > rect.a#b` 由多个复合选择器与组合符组成。
 *
 * 解析阶段只识别类型、`.class`、`#id`、`*`、后代与子代；伪类与属性选择器在更上层跳过。
 */
public class CssSelector <: ToString {
    public let parts: Array<CssSelectorPart>
    public let combinators: Array<CssCombinator>
    public let specificity: CssSpecificity

    init(parts: Array<CssSelectorPart>, combinators: Array<CssCombinator>) {
        this.parts = parts
        this.combinators = combinators
        var specificity = CssSpecificity.zero
        for (part in parts) {
            var current = CssSpecificity(0, 0, 0)
            match (part.typeName) {
                case Some(_) => current = CssSpecificity(0, 0, 1)
                case None => ()
            }
            if (part.id.isSome()) {
                current = current.plus(CssSpecificity(1, 0, 0))
            }
            current = current.plus(CssSpecificity(0, part.classes.size, 0))
            specificity = specificity.plus(current)
        }
        this.specificity = specificity
    }

    public static func parse(text: String): CssSelector {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            throw invalidValue("选择器不能为空")
        }
        let bytes = trimmed.unsafeBytes()
        let parts = ArrayList<CssSelectorPart>()
        let combinators = ArrayList<CssCombinator>()
        var i = 0
        var sawWhitespace = false
        while (true) {
            i = skipCssSpaces(bytes, i)
            if (i >= bytes.size) {
                break
            }
            if (bytes[i] == b'>') {
                if (parts.size == 0) {
                    throw invalidValue("选择器不能以子代组合符开头")
                }
                if (combinators.size == parts.size) {
                    throw invalidValue("选择器出现连续组合符")
                }
                combinators.add(CssCombinator.Child)
                i++
                continue
            }
            if (parts.size > 0 && combinators.size < parts.size) {
                if (!sawWhitespace) {
                    throw invalidValue("选择器缺少组合符「${text}」")
                }
                combinators.add(CssCombinator.Descendant)
            }
            let startIndex = i
            i = parseCssSelectorPart(bytes, i)
            if (i == startIndex) {
                throw invalidValue("无法解析选择器「${text}」")
            }
            parts.add(buildCssSelectorPart(trimmed, startIndex, i))
            sawWhitespace = false
            let afterPart = i
            i = skipCssSpaces(bytes, i)
            sawWhitespace = i > afterPart
        }
        if (parts.size == 0) {
            throw invalidValue("选择器不能为空")
        }
        if (combinators.size != parts.size - 1) {
            throw invalidValue("选择器组合符数量不匹配")
        }
        CssSelector(parts.toArray(), combinators.toArray())
    }

    /**
     * 匹配元素。当前阶段只提供模型，匹配在 M2.1 选择器任务中实现。
     */
    public func matches(element: SvgElement): Bool {
        false
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..this.parts.size) {
            if (index > 0) {
                match (this.combinators[index - 1]) {
                    case Child => out.append(" > ")
                    case Descendant => out.append(" ")
                }
            }
            out.append(this.parts[index].toString())
        }
        out.toString()
    }
}

private func skipCssSpaces(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start
    while (i < bytes.size && isCssSpace(bytes[i])) {
        i++
    }
    i
}

/** 返回复合选择器结束位置；遇到 `:` / `[` / `]` 抛错。 */
private func parseCssSelectorPart(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start
    var sawType = false
    if (i < bytes.size && bytes[i] == b'*') {
        sawType = true
        i++
    } else if (i < bytes.size && isCssIdentStart(bytes, i)) {
        sawType = true
        while (i < bytes.size && isCssIdentByte(bytes[i])) {
            i++
        }
    }
    var sawQualifier = false
    while (i < bytes.size && (bytes[i] == b'.' || bytes[i] == b'#')) {
        sawQualifier = true
        i++
        let nameStart = i
        while (i < bytes.size && isCssIdentByte(bytes[i])) {
            i++
        }
        if (i == nameStart) {
            throw invalidValue("选择器限定符缺少名称")
        }
    }
    if (i < bytes.size && (bytes[i] == b':' || bytes[i] == b'[' || bytes[i] == b']')) {
        throw invalidValue("暂不支持的选择器语法")
    }
    if (!sawType && !sawQualifier) {
        throw invalidValue("无法识别选择器")
    }
    i
}

private func buildCssSelectorPart(text: String, start: Int64, end: Int64): CssSelectorPart {
    let bytes = text.unsafeBytes()
    var i = start
    var typeName: ?String = None
    if (bytes[i] == b'*') {
        i++
    } else if (isCssIdentStart(bytes, i)) {
        let nameStart = i
        while (i < end && isCssIdentByte(bytes[i])) {
            i++
        }
        typeName = Some(decodeCssIdent(text[nameStart..i]))
    }
    var id: ?String = None
    let classes = ArrayList<String>()
    while (i < end && (bytes[i] == b'.' || bytes[i] == b'#')) {
        let marker = bytes[i]
        i++
        let nameStart = i
        while (i < end && isCssIdentByte(bytes[i])) {
            i++
        }
        let name = decodeCssIdent(text[nameStart..i])
        if (marker == b'#') {
            id = Some(name)
        } else {
            classes.add(name)
        }
    }
    CssSelectorPart(typeName, id, classes.toArray())
}
