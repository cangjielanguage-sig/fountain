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
package fountain::f_email.model

import cangjie_tpc::charset4cj.charset.encoding.Charset

/**
 * `Content-Type`。
 *
 * 解析规则：引号参数（含 `\"` 转义）、参数间注释、分号在引号内不切分；
 * 类型与子类型统一小写后比较，参数名小写、参数值保留原样；
 * 缺失时默认 `text/plain; charset=us-ascii`（RFC 2045）。
 */
public class ContentType <: ToString {
    public let typeName: String
    public let subtype: String
    private let parameterMap: MimeParameters

    public init(mediaType: String, parameters!: MimeParameters = MimeParameters()) {
        let slash = mediaType.indexOf("/") ?? -1
        if (slash < 0) {
            this.typeName = mediaType.trimAscii().toAsciiLower()
            this.subtype = ""
        } else {
            this.typeName = mediaType[0..slash].trimAscii().toAsciiLower()
            this.subtype = mediaType[(slash + 1)..].trimAscii().toAsciiLower()
        }
        this.parameterMap = parameters
    }

    private init(typeName: String, subtype: String, parameters: MimeParameters) {
        this.typeName = typeName
        this.subtype = subtype
        this.parameterMap = parameters
    }

    /** RFC 2045 的缺省值。 */
    public static func defaultText(): ContentType {
        let params = MimeParameters()
        params.add("charset", "us-ascii")
        ContentType("text", "plain", params)
    }

    public static func parse(value: String, strict!: Bool = false): ContentType {
        let text = value.trimAscii()
        if (text.size == 0) {
            return defaultText()
        }
        let semicolon = indexOfSemicolon(text)
        let mediaType = if (semicolon < 0) {
            text
        } else {
            text[0..semicolon].trimAscii()
        }
        let params = if (semicolon < 0) {
            MimeParameters()
        } else {
            MimeParameter.parse(text[(semicolon + 1)..], strict: strict)
        }
        let slash = mediaType.indexOf("/") ?? -1
        if (slash < 0) {
            ContentType(mediaType.toAsciiLower(), "", params)
        } else {
            ContentType(
                mediaType[0..slash].trimAscii().toAsciiLower(),
                mediaType[(slash + 1)..].trimAscii().toAsciiLower(),
                params
            )
        }
    }

    public prop mediaType: String {
        get() {
            if (subtype.size == 0) {
                typeName
            } else {
                "${typeName}/${subtype}"
            }
        }
    }

    public prop parameters: MimeParameters {
        get() {
            parameterMap
        }
    }

    public func isMultipart(): Bool {
        typeName == "multipart"
    }

    public func isText(): Bool {
        typeName == "text"
    }

    /** 声明字符集解析结果；未声明时返回 `None`（由 `CharsetResolver` 决定缺省值）。 */
    public func charset(): ?Charset {
        if (let Some(name) <- parameterMap.get("charset")) {
            return Some(CharsetResolver.resolve(Some(name)))
        }
        None<Charset>
    }

    public func charsetName(): ?String {
        parameterMap.get("charset")
    }

    public func boundary(): ?String {
        parameterMap.get("boundary")
    }

    /** `name` 参数（附件名）已按 RFC 2231 解码。 */
    public func name(): ?String {
        parameterMap.get("name")
    }

    public func toString(): String {
        "${mediaType}${parameterMap.toHeaderValue()}"
    }

    static func indexOfSemicolon(text: String): Int64 {
        var inQuote = false
        var escaped = false
        var depth = 0
        let bytes = text.toArray()
        var i = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (escaped) {
                escaped = false
                i += 1
                continue
            }
            if (b == b'\\' && inQuote) {
                escaped = true
                i += 1
                continue
            }
            if (b == b'"') {
                inQuote = !inQuote
            } else if (!inQuote) {
                if (b == b'(') {
                    depth += 1
                } else if (b == b')' && depth > 0) {
                    depth -= 1
                } else if (b == b';' && depth == 0) {
                    return i
                }
            }
            i += 1
        }
        -1
    }
}

/**
 * `Content-Disposition`。
 *
 * `filename` 同时兼容 RFC 2231（标准）与 RFC 2047（旧客户端的非标准写法）。
 */
public class ContentDisposition <: ToString {
    public let disposition: String
    private let parameterMap: MimeParameters

    public init(disposition: String, parameters!: MimeParameters = MimeParameters()) {
        this.disposition = disposition.trimAscii().toAsciiLower()
        this.parameterMap = parameters
    }

    public static func parse(value: String, strict!: Bool = false): ContentDisposition {
        let text = value.trimAscii()
        if (text.size == 0) {
            return ContentDisposition("inline")
        }
        let semicolon = ContentType.indexOfSemicolon(text)
        if (semicolon < 0) {
            return ContentDisposition(text.toAsciiLower())
        }
        ContentDisposition(
            text[0..semicolon].trimAscii().toAsciiLower(),
            parameters: MimeParameter.parse(text[(semicolon + 1)..], strict: strict)
        )
    }

    public prop isAttachment: Bool {
        get() {
            disposition == "attachment"
        }
    }

    public prop isInline: Bool {
        get() {
            disposition == "inline"
        }
    }

    public func filename(): ?String {
        parameterMap.get("filename")
    }

    public func parameters(): MimeParameters {
        parameterMap
    }

    public func toString(): String {
        "${disposition}${parameterMap.toHeaderValue()}"
    }
}
