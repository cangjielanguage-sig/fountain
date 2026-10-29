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

/**
 * 写方向（字符 → 字节）的编码失败策略。
 *
 * 检测用**往返校验**（encode → decode → 比较），不依赖 `Encoder.encode` 抛异常：
 * 实测 `charset4cj` 对不可映射字符是静默替换成 `?`，不会报错。
 */
public enum InvalidCharMode <: Equatable<InvalidCharMode> & ToString {
    /** 默认：抛 `XmlException`，带码点与文本内位置。 */
    | Throw
    /** 用 `?`（0x3F）代替——`U+FFFD` 在 GBK 里表示不了。 */
    | Replace

    public operator func ==(that: InvalidCharMode): Bool {
        match ((this, that)) {
            case (Throw, Throw) => true
            case (Replace, Replace) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Throw => "Throw"
            case Replace => "Replace"
        }
    }
}

/** 文本节点的 CDATA 输出策略。 */
public enum CdataMode <: Equatable<CdataMode> & ToString {
    /** 默认：常规转义，不产 CDATA。 */
    | Auto
    /** 所有文本节点用 `<![CDATA[ … ]]>` 包裹（`]]>` 拆分为 `]]]]><![CDATA[>`）。 */
    | Always
    /** 强制转义，即使内容适合 CDATA。 */
    | Never

    public operator func ==(that: CdataMode): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Always, Always) => true
            case (Never, Never) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "Auto"
            case Always => "Always"
            case Never => "Never"
        }
    }
}

/** 写侧要输出的 DOCTYPE（含内部子集实体声明）。 */
public class Doctype <: ToString {
    public let name: String
    public let publicId: ?String
    public let systemId: ?String
    public let entities: Array<EntityDecl>

    public init(
        name: String,
        publicId!: ?String = None,
        systemId!: ?String = None,
        entities!: Array<EntityDecl> = Array<EntityDecl>()
    ) {
        this.name = name
        this.publicId = publicId
        this.systemId = systemId
        this.entities = entities
    }

    public func isDeclared(entityName: String): Bool {
        for (decl in this.entities) {
            if (decl.name == entityName) {
                return true
            }
        }
        false
    }

    public func toString(): String {
        "<!DOCTYPE ${this.name}>"
    }
}

/** 生成器选项。 */
public struct XmlWriterOptions {
    /** `None` = 紧凑模式（默认），不产生任何额外空白。 */
    public let indent: ?String

    public let cdata: CdataMode

    public let charset: Charset

    public let onInvalidChar: InvalidCharMode

    /** 未在 `doctype` 里声明的实体引用是否报错。 */
    public let strictEntities: Bool

    /** 输出时使用的 DOCTYPE（含内部子集）。 */
    public let doctype: ?Doctype

    public init(
        indent!: ?String = None,
        cdata!: CdataMode = CdataMode.Auto,
        charset!: Charset = Charsets.UTF8,
        onInvalidChar!: InvalidCharMode = InvalidCharMode.Throw,
        strictEntities!: Bool = true,
        doctype!: ?Doctype = None
    ) {
        this.indent = indent
        this.cdata = cdata
        this.charset = charset
        this.onInvalidChar = onInvalidChar
        this.strictEntities = strictEntities
        this.doctype = doctype
    }
}
