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
    public let combinator: ?CssCombinator

    init(typeName: ?String, id: ?String, classes: Array<String>, combinator: ?CssCombinator) {
        this.typeName = typeName
        this.id = id
        this.classes = classes
        this.combinator = combinator
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
            parts.add(
                buildCssSelectorPart(
                    trimmed,
                    startIndex,
                    i,
                    if (parts.size == 0) { None } else { Some(combinators[parts.size - 1]) }
                )
            )
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

    /** 从右端开始匹配；后代组合符逐级回溯祖先，子代只检查直接父元素。 */
    public func matches(element: SvgElement): Bool {
        this.matchPartAt(this.parts.size - 1, element)
    }

    private func matchPartAt(index: Int64, element: SvgElement): Bool {
        if (!cssPartMatches(this.parts[index], element)) {
            return false
        }
        if (index == 0) {
            return true
        }
        match (this.combinators[index - 1]) {
            case Child =>
                match (element.parent) {
                    case Some(parent) => this.matchPartAt(index - 1, parent)
                    case None => false
                }
            case Descendant =>
                var current = element.parent
                while (true) {
                    match (current) {
                        case Some(parent) =>
                            if (this.matchPartAt(index - 1, parent)) {
                                return true
                            }
                            current = parent.parent
                        case None => return false
                    }
                }
                false
        }
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

private func buildCssSelectorPart(
    text: String,
    start: Int64,
    end: Int64,
    combinator: ?CssCombinator
): CssSelectorPart {
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
    CssSelectorPart(typeName, id, classes.toArray(), combinator)
}

/** 复合选择器与单个元素匹配：类型、id、全部 class 词。 */
private func cssPartMatches(part: CssSelectorPart, element: SvgElement): Bool {
    match (part.typeName) {
        case Some(name) => if (element.tag != name) {
            return false
        }
        case None => ()
    }
    match (part.id) {
        case Some(id) => if (element.attr("id") != Some(id)) {
            return false
        }
        case None => ()
    }
    if (part.classes.size > 0) {
        match (element.attr("class")) {
            case Some(text) =>
                for (className in part.classes) {
                    if (!cssClassListContains(text, className)) {
                        return false
                    }
                }
            case None => return false
        }
    }
    true
}

/** 以 ASCII 空白分隔的 class 词表。 */
internal func cssClassListContains(text: String, name: String): Bool {
    let bytes = text.unsafeBytes()
    var i = 0
    while (i < bytes.size) {
        while (i < bytes.size && isCssSpace(bytes[i])) {
            i++
        }
        let start = i
        while (i < bytes.size && !isCssSpace(bytes[i])) {
            i++
        }
        if (i > start && text[start..i] == name) {
            return true
        }
    }
    false
}

/**
 * 右端简单选择器倒排桶：按 id / class / type 预过滤候选规则。
 *
 * 非循环引用、非通配选择器才进入桶；通配与多选择器规则走 `universal` 列表。
 */
internal class CssSelectorIndex {
    private let byId = HashMap<String, ArrayList<Int64>>()
    private let byClass = HashMap<String, ArrayList<Int64>>()
    private let byType = HashMap<String, ArrayList<Int64>>()
    private let universal = ArrayList<Int64>()

    init(rules: Array<CssRule>) {
        for (index in 0..rules.size) {
            let selector = rules[index].selectors[0]
            let rightmost = selector.parts[selector.parts.size - 1]
            match (rightmost.id) {
                case Some(id) => CssSelectorIndex.addTo(this.byId, id, index)
                case None =>
                    if (rightmost.classes.size > 0) {
                        CssSelectorIndex.addTo(this.byClass, rightmost.classes[0], index)
                    } else {
                        match (rightmost.typeName) {
                            case Some(name) => CssSelectorIndex.addTo(this.byType, name, index)
                            case None => this.universal.add(index)
                        }
                    }
            }
        }
    }

    /** 返回可能匹配的规则下标，去重后升序；调用方仍需完整 `matches` 校验。 */
    func candidates(element: SvgElement): Array<Int64> {
        let seen = HashMap<Int64, Bool>()
        let result = ArrayList<Int64>()
        CssSelectorIndex.collect(this.universal, seen, result)
        match (element.attr("id")) {
            case Some(id) =>
                match (this.byId.get(id)) {
                    case Some(list) => CssSelectorIndex.collect(list, seen, result)
                    case None => ()
                }
            case None => ()
        }
        match (element.attr("class")) {
            case Some(text) =>
                for ((key, list) in this.byClass) {
                    if (cssClassListContains(text, key)) {
                        CssSelectorIndex.collect(list, seen, result)
                    }
                }
            case None => ()
        }
        match (this.byType.get(element.tag)) {
            case Some(list) => CssSelectorIndex.collect(list, seen, result)
            case None => ()
        }
        var i = 1
        while (i < result.size) {
            let value = result[i]
            var j = i - 1
            while (j >= 0 && result[j] > value) {
                result[j + 1] = result[j]
                j--
            }
            result[j + 1] = value
            i++
        }
        result.toArray()
    }

    private static func addTo(bucket: HashMap<String, ArrayList<Int64>>, key: String, index: Int64): Unit {
        match (bucket.get(key)) {
            case Some(list) => list.add(index)
            case None =>
                let created = ArrayList<Int64>()
                created.add(index)
                bucket[key] = created
        }
    }

    private static func collect(
        source: ArrayList<Int64>,
        seen: HashMap<Int64, Bool>,
        result: ArrayList<Int64>
    ): Unit {
        for (index in source) {
            if (seen.get(index).isNone()) {
                seen[index] = true
                result.add(index)
            }
        }
    }
}
