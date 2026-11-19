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

import fountain::f_base.StringGenerator

/**
 * 解析事件的**唯一定义**。不另设 kind 枚举——两套定义迟早会漂移。
 *
 * 分支固定 10 个，`match` 可穷尽。顺序约定：
 * `StartDocument → XmlDeclaration? → DocType? → (Comment|PI)* → StartElement(root) →
 * …递归… → EndElement(root) → (Comment|PI)* → EndDocument`。
 */
public enum XmlEvent <: ToString {
    | StartDocument
    | XmlDeclaration(String, ?String, ?Bool)
    | DocType(String, ?String, ?String)
    | StartElement(QName, Array<XmlAttribute>, Bool)
    | EndElement(QName)
    | Text(String)
    | CData(String)
    | Comment(String)
    | ProcessingInstruction(String, String)
    | EndDocument

    /**
     * 稳定文本格式，供「推 / 拉事件日志逐行 diff」使用。
     *
     * `TEXT "..." <字符数>` 的字符数是 rune 数（不是字节数），便于断言文本拆分行为。
     * 实现 `ToString` 而**不实现 `Equatable`**：带载荷的枚举比较没有语义。
     */
    public func toString(): String {
        match (this) {
            case StartDocument => "START document"
            case XmlDeclaration(version, encoding, standalone) =>
                "DECL ${version} encoding=${present(encoding)} standalone=${standaloneText(standalone)}"
            case DocType(name, publicId, systemId) =>
                "DOCTYPE ${name} ${present(publicId)} ${present(systemId)}"
            case StartElement(name, attrs, selfClosing) =>
                "START ${qnameText(name)} attrs=${attrs.size} selfClosing=${selfClosing}"
            case EndElement(name) => "END ${qnameText(name)}"
            case Text(value) => "TEXT \"${escape(value)}\" ${runeCount(value)}"
            case CData(value) => "CDATA \"${escape(value)}\" ${runeCount(value)}"
            case Comment(value) => "COMMENT \"${escape(value)}\""
            case ProcessingInstruction(target, data) => "PI ${target} \"${escape(data)}\""
            case EndDocument => "END document"
        }
    }

    private static func qnameText(name: QName): String {
        "QName(${present(name.prefix)},${name.local},${present(name.uri)})"
    }

    private static func present(value: ?String): String {
        match (value) {
            case Some(v) => v
            case None => "-"
        }
    }

    private static func standaloneText(value: ?Bool): String {
        match (value) {
            case Some(true) => "yes"
            case Some(false) => "no"
            case None => "-"
        }
    }

    private static func runeCount(value: String): Int64 {
        var count: Int64 = 0
        for (_ in value.runes()) {
            count++
        }
        count
    }

    private static func escape(value: String): String {
        let out = StringGenerator()
        for (r in value.runes()) {
            match (r) {
                case r'"' => out.append<String>("\\\"")
                case r'\\' => out.append<String>("\\\\")
                case r'\n' => out.append<String>("\\n")
                case r'\r' => out.append<String>("\\r")
                case r'\t' => out.append<String>("\\t")
                case _ => out.append(r)
            }
        }
        out.toString()
    }
}

/**
 * 回调的返回值：控制解析器下一步做什么。
 *
 * 仓颉 enum **不自动派生** `==`，声明 `Equatable` 后必须显式实现 `operator func ==`，
 * 否则编译失败；靠 `match` 手写比较还能在新增分支时被穷尽性检查拦住。
 */
public enum XmlAction <: Equatable<XmlAction> & ToString {
    | Continue
    | SkipSubtree
    | Stop

    public operator func ==(that: XmlAction): Bool {
        match ((this, that)) {
            case (Continue, Continue) => true
            case (SkipSubtree, SkipSubtree) => true
            case (Stop, Stop) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Continue => "Continue"
            case SkipSubtree => "SkipSubtree"
            case Stop => "Stop"
        }
    }
}

/**
 * 事件处理器：**所有方法都有默认实现**（返回 `Continue`），实现方只覆盖关心的方法。
 *
 * 不提供 `stop()` / `skipCurrentElement()` 之类的 parser 侧方法——控制流只靠返回值，
 * 这样推 / 拉两个前端的行为不会分叉。
 */
public interface XmlEventHandler {
    func onStartDocument(): XmlAction {
        XmlAction.Continue
    }

    func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction {
        XmlAction.Continue
    }

    func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction {
        XmlAction.Continue
    }

    func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        XmlAction.Continue
    }

    func onEndElement(name: QName): XmlAction {
        XmlAction.Continue
    }

    func onText(text: String): XmlAction {
        XmlAction.Continue
    }

    func onCData(text: String): XmlAction {
        XmlAction.Continue
    }

    func onComment(text: String): XmlAction {
        XmlAction.Continue
    }

    func onProcessingInstruction(target: String, data: String): XmlAction {
        XmlAction.Continue
    }

    func onEndDocument(): XmlAction {
        XmlAction.Continue
    }
}
