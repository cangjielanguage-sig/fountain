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

import fountain::f_xml.XmlParserOptions

/** 不安全内容的处理策略。 */
public enum SvgUnsafePolicy <: Equatable<SvgUnsafePolicy> & ToString {
    /** 抛 `Security`。 */
    | Reject
    /** 移除并记 warning（默认）。 */
    | Remove
    /** 保留，调用方自担风险。 */
    | Keep

    public operator func ==(that: SvgUnsafePolicy): Bool {
        match ((this, that)) {
            case (Reject, Reject) => true
            case (Remove, Remove) => true
            case (Keep, Keep) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Reject => "Reject"
            case Remove => "Remove"
            case Keep => "Keep"
        }
    }
}

/** 安全选项。所有放行开关只影响对应类别。 */
public struct SvgSecurityOptions {
    public let unsafePolicy: SvgUnsafePolicy
    public let allowScript: Bool
    public let allowEventAttributes: Bool
    public let allowExternalReferences: Bool
    public let allowDataImages: Bool
    public let maxElements: Int64
    public let maxDepth: Int64
    /** gzip 解压输出上限（字节），默认 64 MiB。 */
    public let maxDecompressedBytes: Int64

    public init(
        unsafePolicy!: SvgUnsafePolicy = SvgUnsafePolicy.Remove,
        allowScript!: Bool = false,
        allowEventAttributes!: Bool = false,
        allowExternalReferences!: Bool = false,
        allowDataImages!: Bool = true,
        maxElements!: Int64 = 1_000_000,
        maxDepth!: Int64 = 512,
        maxDecompressedBytes!: Int64 = 64 * 1024 * 1024
    ) {
        if (maxDecompressedBytes <= 0) {
            throw invalidValue("maxDecompressedBytes 必须为正，实际 ${maxDecompressedBytes}")
        }
        this.unsafePolicy = unsafePolicy
        this.allowScript = allowScript
        this.allowEventAttributes = allowEventAttributes
        this.allowExternalReferences = allowExternalReferences
        this.allowDataImages = allowDataImages
        this.maxElements = maxElements
        this.maxDepth = maxDepth
        this.maxDecompressedBytes = maxDecompressedBytes
    }
}

/** 解析选项。 */
public struct SvgParseOptions {
    public let strict: Bool
    public let security: SvgSecurityOptions
    /** 原样透传给 `f_xml`。 */
    public let xml: XmlParserOptions
    /** 内部标记：正在解析 provider 返回的外部文档。 */
    internal let externalDocumentMode: Bool

    public init(
        strict!: Bool = false,
        security!: SvgSecurityOptions = SvgSecurityOptions(),
        xml!: XmlParserOptions = XmlParserOptions()
    ) {
        this.strict = strict
        this.security = security
        this.xml = xml
        this.externalDocumentMode = false
    }

    /** 外部文档专用：保留 `strict` 供其他检查使用，但外部 `href` 一律按 `Remove`。 */
    internal init(
        strict!: Bool,
        security!: SvgSecurityOptions,
        xml!: XmlParserOptions,
        externalDocumentMode!: Bool
    ) {
        this.strict = strict
        this.security = security
        this.xml = xml
        this.externalDocumentMode = externalDocumentMode
    }
}
