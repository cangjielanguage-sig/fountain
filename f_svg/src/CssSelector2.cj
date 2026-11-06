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

/** 属性选择器的比较运算符。 */
public enum CssAttributeOperator <: Equatable<CssAttributeOperator> & ToString {
    | Exists
    | Equals
    | Includes
    | DashMatch
    | Prefix
    | Suffix
    | Substring

    public operator func ==(that: CssAttributeOperator): Bool {
        match ((this, that)) {
            case (Exists, Exists) => true
            case (Equals, Equals) => true
            case (Includes, Includes) => true
            case (DashMatch, DashMatch) => true
            case (Prefix, Prefix) => true
            case (Suffix, Suffix) => true
            case (Substring, Substring) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Exists => "exists"
            case Equals => "="
            case Includes => "~="
            case DashMatch => "|="
            case Prefix => "^="
            case Suffix => "$="
            case Substring => "*="
        }
    }
}

/**
 * `[attr op value i]` 的解析结果。
 *
 * 字段名 `op` 对应 CSS 规范的「比较运算符」，避免与仓颉关键字 `operator` 冲突。
 */
public struct CssAttributeSelector <: Equatable<CssAttributeSelector> & ToString {
    public let name: String
    public let op: CssAttributeOperator
    public let value: ?String
    public let caseInsensitive: Bool

    public init(
        name: String,
        op: CssAttributeOperator,
        value!: ?String = None,
        caseInsensitive!: Bool = false
    ) {
        this.name = name
        this.op = op
        this.value = value
        this.caseInsensitive = caseInsensitive
    }

    public func toString(): String {
        let flag = if (this.caseInsensitive) { " i" } else { "" }
        match (this.value) {
            case Some(text) => "[${this.name}${this.op.toString()}${text}${flag}]"
            case None => "[${this.name}${flag}]"
        }
    }

    public operator func ==(that: CssAttributeSelector): Bool {
        this.name == that.name && this.op == that.op && this.value == that.value &&
            this.caseInsensitive == that.caseInsensitive
    }
}

/** 结构伪类与否定伪类。`NthChild` / `NthOfType` 保存 `An+B` 的 `(a, b)`。 */
public enum CssPseudoClass <: Equatable<CssPseudoClass> & ToString {
    | Root
    | FirstChild
    | LastChild
    | OnlyChild
    | NthChild(Int64, Int64)
    | FirstOfType
    | LastOfType
    | NthOfType(Int64, Int64)
    | OnlyOfType
    | Empty
    | Not(CssSimpleSelector)

    public operator func ==(that: CssPseudoClass): Bool {
        match ((this, that)) {
            case (Root, Root) => true
            case (FirstChild, FirstChild) => true
            case (LastChild, LastChild) => true
            case (OnlyChild, OnlyChild) => true
            case (NthChild(a1, b1), NthChild(a2, b2)) => a1 == a2 && b1 == b2
            case (FirstOfType, FirstOfType) => true
            case (LastOfType, LastOfType) => true
            case (NthOfType(a1, b1), NthOfType(a2, b2)) => a1 == a2 && b1 == b2
            case (OnlyOfType, OnlyOfType) => true
            case (Empty, Empty) => true
            case (Not(left), Not(right)) => left == right
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Root => ":root"
            case FirstChild => ":first-child"
            case LastChild => ":last-child"
            case OnlyChild => ":only-child"
            case NthChild(a, b) => ":nth-child(${formatCssAnB(a, b)})"
            case FirstOfType => ":first-of-type"
            case LastOfType => ":last-of-type"
            case NthOfType(a, b) => ":nth-of-type(${formatCssAnB(a, b)})"
            case OnlyOfType => ":only-of-type"
            case Empty => ":empty"
            case Not(inner) => ":not(${inner.toString()})"
        }
    }
}

/** 复合选择器中的单个简单选择器。 */
public enum CssSimpleSelectorKind <: Equatable<CssSimpleSelectorKind> & ToString {
    | Universal
    | Type(String)
    | Id(String)
    | Class(String)
    | Attribute(CssAttributeSelector)
    | PseudoClass(CssPseudoClass)

    public operator func ==(that: CssSimpleSelectorKind): Bool {
        match ((this, that)) {
            case (Universal, Universal) => true
            case (Type(left), Type(right)) => left == right
            case (Id(left), Id(right)) => left == right
            case (Class(left), Class(right)) => left == right
            case (Attribute(left), Attribute(right)) => left == right
            case (PseudoClass(left), PseudoClass(right)) => left == right
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Universal => "*"
            case Type(name) => name
            case Id(name) => "#" + name
            case Class(name) => "." + name
            case Attribute(selector) => selector.toString()
            case PseudoClass(pseudo) => pseudo.toString()
        }
    }
}

/** `:not()` 的参数：恰好一个简单选择器。 */
public struct CssSimpleSelector <: Equatable<CssSimpleSelector> & ToString {
    public let kind: CssSimpleSelectorKind

    public init(kind: CssSimpleSelectorKind) {
        this.kind = kind
    }

    public func toString(): String {
        this.kind.toString()
    }

    public operator func ==(that: CssSimpleSelector): Bool {
        this.kind == that.kind
    }
}

/** 一个复合选择器的解析结果：新模型与原 `typeName` / `id` / `classes` 并存。 */
internal class CssSimpleSequence {
    let simples: Array<CssSimpleSelectorKind>
    let typeName: ?String
    let id: ?String
    let classes: Array<String>
    let end: Int64

    init(
        simples: Array<CssSimpleSelectorKind>,
        typeName: ?String,
        id: ?String,
        classes: Array<String>,
        end: Int64
    ) {
        this.simples = simples
        this.typeName = typeName
        this.id = id
        this.classes = classes
        this.end = end
    }
}

internal let CSS_MAX_SIMPLE_SELECTORS: Int64 = 256

/** 解析一个复合选择器；2.1 只接受属性选择器，`:pseudo` 仍视为不支持。 */
internal func parseCssSimpleSequence(text: String, bytes: Array<Byte>, start: Int64): CssSimpleSequence {
    let simples = ArrayList<CssSimpleSelectorKind>()
    let classes = ArrayList<String>()
    var typeName: ?String = None
    var id: ?String = None
    var i = start
    if (i < bytes.size && bytes[i] == b'*') {
        simples.add(CssSimpleSelectorKind.Universal)
        i++
    } else if (i < bytes.size && isCssIdentStart(bytes, i)) {
        let nameStart = i
        while (i < bytes.size && isCssIdentByte(bytes[i])) {
            i++
        }
        let name = decodeCssIdent(text[nameStart..i])
        typeName = Some(name)
        simples.add(CssSimpleSelectorKind.Type(name))
    }
    while (i < bytes.size) {
        let marker = bytes[i]
        if (marker == b'.' || marker == b'#') {
            i++
            let nameStart = i
            while (i < bytes.size && isCssIdentByte(bytes[i])) {
                i++
            }
            if (i == nameStart) {
                throw invalidValue("选择器限定符缺少名称")
            }
            let name = decodeCssIdent(text[nameStart..i])
            if (marker == b'.') {
                classes.add(name)
                simples.add(CssSimpleSelectorKind.Class(name))
            } else {
                id = Some(name)
                simples.add(CssSimpleSelectorKind.Id(name))
            }
        } else if (marker == b'[') {
            i = parseCssAttributeSelector(text, bytes, i, simples)
        } else if (marker == b':') {
            i = parseCssPseudoClass(text, bytes, i, simples, allowNot: true)
        } else {
            break
        }
    }
    if (simples.size == 0) {
        throw invalidValue("无法识别选择器")
    }
    if (simples.size > CSS_MAX_SIMPLE_SELECTORS) {
        throw invalidValue(
            "选择器「${text[start..i]}」含 ${simples.size} 个简单选择器，超过上限 ${CSS_MAX_SIMPLE_SELECTORS}"
        )
    }
    CssSimpleSequence(simples.toArray(), typeName, id, classes.toArray(), i)
}

/** 解析 `[...]`，返回右方括号之后的位置。 */
private func parseCssAttributeSelector(
    text: String,
    bytes: Array<Byte>,
    start: Int64,
    out: ArrayList<CssSimpleSelectorKind>
): Int64 {
    var i = start + 1
    i = skipCssSpaces(bytes, i)
    let nameStart = i
    while (i < bytes.size && isCssIdentByte(bytes[i])) {
        i++
    }
    if (i == nameStart) {
        throw invalidValue("属性选择器缺少属性名")
    }
    let name = decodeCssIdent(text[nameStart..i])
    i = skipCssSpaces(bytes, i)
    if (i >= bytes.size) {
        throw invalidValue("属性选择器缺少右方括号")
    }
    if (bytes[i] == b']') {
        out.add(CssSimpleSelectorKind.Attribute(CssAttributeSelector(name, CssAttributeOperator.Exists)))
        return i + 1
    }
    let parsedOperator = match (parseCssAttributeOperator(bytes, i)) {
        case Some(value) => value
        case None => throw invalidValue("属性选择器出现非法运算符")
    }
    i += cssAttributeOperatorWidth(parsedOperator)
    i = skipCssSpaces(bytes, i)
    let parsedValue = parseCssAttributeValue(text, bytes, i)
    if (parsedValue.text.size == 0) {
        throw invalidValue("属性选择器缺少比较值")
    }
    i = parsedValue.end
    i = skipCssSpaces(bytes, i)
    var caseInsensitive = false
    if (i < bytes.size && (bytes[i] == b'i' || bytes[i] == b'I')) {
        caseInsensitive = true
        i++
        i = skipCssSpaces(bytes, i)
    }
    if (i >= bytes.size || bytes[i] != b']') {
        throw invalidValue("属性选择器缺少右方括号")
    }
    out.add(
        CssSimpleSelectorKind.Attribute(
            CssAttributeSelector(name, parsedOperator, value: Some(parsedValue.text), caseInsensitive: caseInsensitive)
        )
    )
    i + 1
}

private func parseCssAttributeOperator(bytes: Array<Byte>, start: Int64): ?CssAttributeOperator {
    if (start >= bytes.size) {
        return None
    }
    if (bytes[start] == b'=') {
        return Some(CssAttributeOperator.Equals)
    }
    if (start + 1 >= bytes.size || bytes[start + 1] != b'=') {
        return None
    }
    return match (bytes[start]) {
        case b'~' => Some(CssAttributeOperator.Includes)
        case b'|' => Some(CssAttributeOperator.DashMatch)
        case b'^' => Some(CssAttributeOperator.Prefix)
        case b'$' => Some(CssAttributeOperator.Suffix)
        case b'*' => Some(CssAttributeOperator.Substring)
        case _ => None
    }
}

private func cssAttributeOperatorWidth(op: CssAttributeOperator): Int64 {
    match (op) {
        case Exists => 0
        case Equals => 1
        case _ => 2
    }
}

private class CssAttributeValue {
    let text: String
    let end: Int64

    init(text: String, end: Int64) {
        this.text = text
        this.end = end
    }
}

/** 解析比较值：裸标识符 / 单引号 / 双引号；空值返回空文本由调用方判错。 */
private func parseCssAttributeValue(text: String, bytes: Array<Byte>, start: Int64): CssAttributeValue {
    if (start >= bytes.size) {
        return CssAttributeValue("", start)
    }
    let quoteByte = bytes[start]
    if (quoteByte == b'"' || quoteByte == b'\'') {
        var i = start + 1
        let out = StringBuilder()
        while (i < bytes.size && bytes[i] != quoteByte) {
            if (bytes[i] == b'\\' && i + 1 < bytes.size) {
                out.append(text[i + 1..i + 2])
                i += 2
            } else {
                out.append(text[i..i + 1])
                i++
            }
        }
        if (i >= bytes.size) {
            return CssAttributeValue("", i)
        }
        return CssAttributeValue(out.toString(), i + 1)
    }
    var i = start
    while (i < bytes.size && isCssIdentByte(bytes[i])) {
        i++
    }
    CssAttributeValue(text[start..i], i)
}

/** 解析 `:pseudo` / `:pseudo(...)`，返回右括号之后的位置。 */
private func parseCssPseudoClass(
    text: String,
    bytes: Array<Byte>,
    start: Int64,
    out: ArrayList<CssSimpleSelectorKind>,
    allowNot!: Bool
): Int64 {
    var i = start + 1
    if (i < bytes.size && bytes[i] == b':') {
        throw invalidValue("不支持伪元素")
    }
    let nameStart = i
    while (i < bytes.size && isCssIdentByte(bytes[i])) {
        i++
    }
    if (i == nameStart) {
        throw invalidValue("伪类缺少名称")
    }
    let name = text[nameStart..i].toAsciiLower()
    let hasArguments = i < bytes.size && bytes[i] == b'('
    var pseudo: CssPseudoClass
    if (hasArguments) {
        let close = findCssClosingParen(bytes, i)
        if (close < 0) {
            throw invalidValue("伪类缺少右括号")
        }
        let argument = text[i + 1..close].trimAscii()
        i = close + 1
        match (name) {
            case "nth-child" =>
                pseudo = match (parseCssAnB(argument)) {
                    case Some(parsed) => CssPseudoClass.NthChild(parsed[0], parsed[1])
                    case None => throw invalidValue("非法 An+B 表达式「${argument}」")
                }
            case "nth-of-type" =>
                pseudo = match (parseCssAnB(argument)) {
                    case Some(parsed) => CssPseudoClass.NthOfType(parsed[0], parsed[1])
                    case None => throw invalidValue("非法 An+B 表达式「${argument}」")
                }
            case "not" =>
                if (!allowNot) {
                    throw invalidValue("不允许嵌套 :not()")
                }
                pseudo = CssPseudoClass.Not(parseCssNotArgument(argument))
            case _ => throw invalidValue("不支持的伪类「:${name}()」")
        }
    } else {
        pseudo = match (name) {
            case "root" => CssPseudoClass.Root
            case "first-child" => CssPseudoClass.FirstChild
            case "last-child" => CssPseudoClass.LastChild
            case "only-child" => CssPseudoClass.OnlyChild
            case "first-of-type" => CssPseudoClass.FirstOfType
            case "last-of-type" => CssPseudoClass.LastOfType
            case "only-of-type" => CssPseudoClass.OnlyOfType
            case "empty" => CssPseudoClass.Empty
            case _ => throw invalidValue("不支持的伪类「:${name}」")
        }
    }
    out.add(CssSimpleSelectorKind.PseudoClass(pseudo))
    i
}

/** 找到与 `open` 位置左括号配对的右括号；支持嵌套。 */
internal func findCssClosingParen(bytes: Array<Byte>, open: Int64): Int64 {
    var depth = 0
    var i = open
    while (i < bytes.size) {
        if (bytes[i] == b'(') {
            depth++
        } else if (bytes[i] == b')') {
            depth--
            if (depth == 0) {
                return i
            }
        }
        i++
    }
    -1
}

/** `:not()` 的参数：恰好一个简单选择器，禁止复合与嵌套否定。 */
private func parseCssNotArgument(argument: String): CssSimpleSelector {
    let trimmed = argument.trimAscii()
    if (trimmed.size == 0) {
        throw invalidValue(":not() 的参数不能为空")
    }
    let bytes = trimmed.unsafeBytes()
    let simples = ArrayList<CssSimpleSelectorKind>()
    var i = 0
    if (bytes[i] == b'*') {
        simples.add(CssSimpleSelectorKind.Universal)
        i++
    } else if (isCssIdentStart(bytes, i)) {
        let nameStart = i
        while (i < bytes.size && isCssIdentByte(bytes[i])) {
            i++
        }
        simples.add(CssSimpleSelectorKind.Type(decodeCssIdent(trimmed[nameStart..i])))
    } else if (bytes[i] == b'.' || bytes[i] == b'#') {
        let marker = bytes[i]
        i++
        let nameStart = i
        while (i < bytes.size && isCssIdentByte(bytes[i])) {
            i++
        }
        if (i == nameStart) {
            throw invalidValue(":not() 的参数缺少名称")
        }
        let name = decodeCssIdent(trimmed[nameStart..i])
        simples.add(
            if (marker == b'.') {
                CssSimpleSelectorKind.Class(name)
            } else {
                CssSimpleSelectorKind.Id(name)
            }
        )
    } else if (bytes[i] == b'[') {
        i = parseCssAttributeSelector(trimmed, bytes, i, simples)
    } else if (bytes[i] == b':') {
        i = parseCssPseudoClass(trimmed, bytes, i, simples, allowNot: false)
    } else {
        throw invalidValue(":not() 的参数不是简单选择器")
    }
    i = skipCssSpaces(bytes, i)
    if (i != bytes.size || simples.size != 1) {
        throw invalidValue(":not() 只接受单个简单选择器")
    }
    return CssSimpleSelector(simples[0])
}

/** 解析 `An+B`；非法返回 `None`。 */
internal func parseCssAnB(text: String): ?Array<Int64> {
    let compact = removeCssSpaces(text).toAsciiLower()
    if (compact == "odd") {
        return Some([2, 1])
    }
    if (compact == "even") {
        return Some([2, 0])
    }
    if (compact.size == 0) {
        return None
    }
    var nIndex = -1
    let bytes = compact.unsafeBytes()
    for (index in 0..bytes.size) {
        if (bytes[index] == b'n') {
            nIndex = index
            break
        }
    }
    if (nIndex < 0) {
        match (parseCssInteger(compact)) {
            case Some(value) => return Some([0, value])
            case None => return None
        }
    }
    let coefficient = compact[0..nIndex]
    let offset = compact[nIndex + 1..]
    let a = match (coefficient) {
        case "" => 1
        case "+" => 1
        case "-" => -1
        case _ => match (parseCssInteger(coefficient)) {
            case Some(value) => value
            case None => return None
        }
    }
    if (offset.size == 0) {
        return Some([a, 0])
    }
    let first = offset.unsafeBytes()[0]
    if (first != b'+' && first != b'-') {
        return None
    }
    let b = match (parseCssInteger(offset)) {
        case Some(value) => value
        case None => return None
    }
    Some([a, b])
}

/** 严格整数：可选符号 + 至少一位数字。 */
private func parseCssInteger(text: String): ?Int64 {
    if (text.size == 0) {
        return None
    }
    let bytes = text.unsafeBytes()
    var i = 0
    var negative = false
    if (bytes[0] == b'+' || bytes[0] == b'-') {
        negative = bytes[0] == b'-'
        i = 1
    }
    if (i >= bytes.size) {
        return None
    }
    var value: Int64 = 0
    while (i < bytes.size) {
        if (!isCssDigit(bytes[i])) {
            return None
        }
        value = value * 10 + Int64(bytes[i] - b'0')
        i++
    }
    if (negative) {
        -value
    } else {
        value
    }
}

private func removeCssSpaces(text: String): String {
    let out = StringBuilder()
    let bytes = text.unsafeBytes()
    var start = 0
    for (index in 0..bytes.size) {
        if (isCssSpace(bytes[index])) {
            if (index > start) {
                out.append(text[start..index])
            }
            start = index + 1
        }
    }
    if (start < bytes.size) {
        out.append(text[start..])
    }
    out.toString()
}

/** `index`（1 起）是否满足 `An+B`。 */
internal func cssAnBMatches(a: Int64, b: Int64, index: Int64): Bool {
    if (index < 1) {
        return false
    }
    if (a == 0) {
        return index == b
    }
    let delta = index - b
    if (delta % a != 0) {
        return false
    }
    delta / a >= 0
}

/** 元素在父元素元素子节点中的 1-based 序号；根元素为 1。 */
internal func cssElementSiblingIndex(element: SvgElement): Int64 {
    match (element.parent) {
        case None => 1
        case Some(parent) =>
            var position = 0
            for (node in parent.children) {
                match (node) {
                    case ElementNode(child) =>
                        position++
                        if (child == element) {
                            return position
                        }
                    case _ => ()
                }
            }
            position
    }
}

internal func cssElementSiblingCount(element: SvgElement): Int64 {
    match (element.parent) {
        case None => 1
        case Some(parent) =>
            var count = 0
            for (node in parent.children) {
                match (node) {
                    case ElementNode(_) => count++
                    case _ => ()
                }
            }
            count
    }
}

/** 同标签兄弟中的 1-based 序号。 */
internal func cssOfTypeIndex(element: SvgElement): Int64 {
    match (element.parent) {
        case None => 1
        case Some(parent) =>
            var position = 0
            for (node in parent.children) {
                match (node) {
                    case ElementNode(child) =>
                        if (child.tag == element.tag) {
                            position++
                            if (child == element) {
                                return position
                            }
                        }
                    case _ => ()
                }
            }
            position
    }
}

internal func cssOfTypeCount(element: SvgElement): Int64 {
    match (element.parent) {
        case None => 1
        case Some(parent) =>
            var count = 0
            for (node in parent.children) {
                match (node) {
                    case ElementNode(child) => if (child.tag == element.tag) {
                        count++
                    }
                    case _ => ()
                }
            }
            count
    }
}

/** 前一个元素兄弟；忽略文本、注释与 PI。 */
internal func cssPreviousElementSibling(element: SvgElement): ?SvgElement {
    match (element.parent) {
        case None => None
        case Some(parent) =>
            var previous: ?SvgElement = None
            for (node in parent.children) {
                match (node) {
                    case ElementNode(child) =>
                        if (child == element) {
                            return previous
                        }
                        previous = Some(child)
                    case _ => ()
                }
            }
            None
    }
}

/** `:empty`：无元素子节点，且文本内容全为空白。 */
internal func cssElementIsEmpty(element: SvgElement): Bool {
    for (node in element.children) {
        match (node) {
            case ElementNode(_) => return false
            case TextNode(text) => if (!isCssWhitespaceText(text)) {
                return false
            }
            case CDataNode(text) => if (!isCssWhitespaceText(text)) {
                return false
            }
            case _ => ()
        }
    }
    true
}

private func isCssWhitespaceText(text: String): Bool {
    for (byte in text.unsafeBytes()) {
        if (!isCssSpace(byte)) {
            return false
        }
    }
    true
}

/** 伪类求值。 */
internal func cssPseudoMatches(pseudo: CssPseudoClass, element: SvgElement): Bool {
    match (pseudo) {
        case Root => element.parent.isNone()
        case FirstChild => cssElementSiblingIndex(element) == 1
        case LastChild => cssElementSiblingIndex(element) == cssElementSiblingCount(element)
        case OnlyChild => cssElementSiblingCount(element) == 1
        case NthChild(a, b) => cssAnBMatches(a, b, cssElementSiblingIndex(element))
        case FirstOfType => cssOfTypeIndex(element) == 1
        case LastOfType => cssOfTypeIndex(element) == cssOfTypeCount(element)
        case OnlyOfType => cssOfTypeCount(element) == 1
        case NthOfType(a, b) => cssAnBMatches(a, b, cssOfTypeIndex(element))
        case Empty => cssElementIsEmpty(element)
        case Not(inner) => !cssSimpleSelectorMatches(inner.kind, element)
    }
}

/** 复合选择器的特异性：id +1，类 / 属性 +1，类型 / 伪类 +1，`*` 不计。 */
internal func cssSequenceSpecificity(simples: Array<CssSimpleSelectorKind>): CssSpecificity {
    var ids: Int64 = 0
    var classes: Int64 = 0
    var types: Int64 = 0
    for (simple in simples) {
        match (simple) {
            case Universal => ()
            case Type(_) => types++
            case Id(_) => ids++
            case Class(_) => classes++
            case Attribute(_) => classes++
            case PseudoClass(_) => types++
        }
    }
    CssSpecificity(ids, classes, types)
}

/** 复合选择器与单个元素匹配：逐个简单选择器求值。 */
internal func cssSequenceMatches(simples: Array<CssSimpleSelectorKind>, element: SvgElement): Bool {
    for (simple in simples) {
        if (!cssSimpleSelectorMatches(simple, element)) {
            return false
        }
    }
    true
}

/** 单个简单选择器匹配。伪类分支在 2.2 接入结构匹配。 */
internal func cssSimpleSelectorMatches(kind: CssSimpleSelectorKind, element: SvgElement): Bool {
    match (kind) {
        case Universal => true
        case Type(name) => element.tag == name
        case Id(name) => element.attr("id") == Some(name)
        case Class(name) => match (element.attr("class")) {
            case Some(text) => cssClassListContains(text, name)
            case None => false
        }
        case Attribute(selector) => cssAttributeMatches(selector, element)
        case PseudoClass(pseudo) => cssPseudoMatches(pseudo, element)
    }
}

/** 属性选择器求值。 */
internal func cssAttributeMatches(selector: CssAttributeSelector, element: SvgElement): Bool {
    let actual = match (element.attr(selector.name)) {
        case Some(value) => value
        case None => return false
    }
    match (selector.op) {
        case Exists => return true
        case _ => ()
    }
    let expected = selector.value ?? ""
    let left = if (selector.caseInsensitive) { actual.toAsciiLower() } else { actual }
    let right = if (selector.caseInsensitive) { expected.toAsciiLower() } else { expected }
    match (selector.op) {
        case Exists => true
        case Equals => left == right
        case Includes =>
            for (word in splitCssWhitespaceWords(left)) {
                if (word == right) {
                    return true
                }
            }
            false
        case DashMatch => left == right || left.startsWith(right + "-")
        case Prefix => left.startsWith(right)
        case Suffix => left.endsWith(right)
        case Substring => left.contains(right)
    }
}

internal func splitCssWhitespaceWords(text: String): Array<String> {
    let result = ArrayList<String>()
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
        if (i > start) {
            result.add(text[start..i])
        }
    }
    result.toArray()
}

/** `An+B` 的规范文本形式，用于 `toString`。 */
internal func formatCssAnB(a: Int64, b: Int64): String {
    if (a == 0) {
        return b.toString()
    }
    let prefix = match (a) {
        case 1 => ""
        case -1 => "-"
        case _ => a.toString()
    }
    let body = "${prefix}n"
    if (b > 0) {
        return "${body}+${b}"
    }
    if (b < 0) {
        return "${body}${b}"
    }
    body
}
