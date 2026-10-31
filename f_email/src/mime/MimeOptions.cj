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
package fountain::f_email.mime

import std.fs.Path
import cangjie_tpc::charset4cj.charset.Charsets
import cangjie_tpc::charset4cj.charset.encoding.Charset
import fountain::f_email.model.TransferEncoding

/**
 * 解析限制。
 *
 * 默认值按设计文档：头部总字节 256 KB、单行 64 KB、part 数 1000、深度 32；
 * `maxBodyBytes = 0` 表示不限制解码后正文大小。
 */
public struct MimeParseOptions {
    public let maxHeaderBytes: Int64
    public let maxHeaderLine: Int64
    public let maxParts: Int64
    public let maxDepth: Int64
    public let maxBodyBytes: Int64
    /** 解码后不超过该值的 `text` 类型进 `PartBody.Text`，其余进 `BodySource`。 */
    public let inlineTextLimit: Int64
    /** 超过该值的叶子正文落临时文件。 */
    public let spoolThreshold: Int64
    public let spoolDir: ?Path
    public let strict: Bool
    public let defaultCharset: Charset

    public init(
        maxHeaderBytes!: Int64 = 256 * 1024,
        maxHeaderLine!: Int64 = 64 * 1024,
        maxParts!: Int64 = 1000,
        maxDepth!: Int64 = 32,
        maxBodyBytes!: Int64 = 0,
        inlineTextLimit!: Int64 = 256 * 1024,
        spoolThreshold!: Int64 = 1024 * 1024,
        spoolDir!: ?Path = None,
        strict!: Bool = false,
        defaultCharset!: Charset = Charsets.UTF8
    ) {
        this.maxHeaderBytes = maxHeaderBytes
        this.maxHeaderLine = maxHeaderLine
        this.maxParts = maxParts
        this.maxDepth = maxDepth
        this.maxBodyBytes = maxBodyBytes
        this.inlineTextLimit = inlineTextLimit
        this.spoolThreshold = spoolThreshold
        this.spoolDir = spoolDir
        this.strict = strict
        this.defaultCharset = defaultCharset
    }
}

/** 生成选项。 */
public struct MimeWriteOptions {
    /** 服务器支持 `8BITMIME` 时才允许文本走 `8bit`。 */
    public let allow8Bit: Bool
    /** 头部折行宽度。 */
    public let maxLineLength: Int64
    /** base64 / QP 的正文行长。 */
    public let bodyLineLength: Int64
    /** >0 时超过即抛。 */
    public let maxBytes: Int64
    /** 硬约束；冲突抛 [MimeException]。 */
    public let forceEncoding: ?TransferEncoding
    public let boundaryPrefix: String
    /** true 时头部直写 UTF-8（`SMTPUTF8` / `UTF8=ACCEPT` 场景）。 */
    public let utf8Headers: Bool

    public init(
        allow8Bit!: Bool = false,
        maxLineLength!: Int64 = 78,
        bodyLineLength!: Int64 = 76,
        maxBytes!: Int64 = 0,
        forceEncoding!: ?TransferEncoding = None,
        boundaryPrefix!: String = "=_fountain_",
        utf8Headers!: Bool = false
    ) {
        this.allow8Bit = allow8Bit
        this.maxLineLength = maxLineLength
        this.bodyLineLength = bodyLineLength
        this.maxBytes = maxBytes
        this.forceEncoding = forceEncoding
        this.boundaryPrefix = boundaryPrefix
        this.utf8Headers = utf8Headers
    }
}
