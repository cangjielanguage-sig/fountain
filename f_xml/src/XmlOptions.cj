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

import std.fs.Path

/**
 * 读方向（字节 → 字符）的解码失败策略。
 *
 * 不提供「跳过」模式：丢字节会让后续全部错位，解出「看起来正常但内容错误」的文本，
 * 比一个可见的 `U+FFFD` 难查得多。
 */
public enum InvalidByteMode <: Equatable<InvalidByteMode> & ToString {
    /** 默认：抛 `XmlException`，消息带行号、列号与坏字节偏移。 */
    | Strict
    /** 按 RFC 3629 maximal subpart 消费，每个最大子部分产出恰好一个 `U+FFFD`。 */
    | Replace

    public operator func ==(that: InvalidByteMode): Bool {
        match ((this, that)) {
            case (Strict, Strict) => true
            case (Replace, Replace) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Strict => "Strict"
            case Replace => "Replace"
        }
    }
}

/**
 * 实体膨胀的溢出策略。
 *
 * 软阈值（单实体 / 总量）在 `Strict` 下直接抛错，在 `Spill` 下转写临时文件继续；
 * 硬限制（深度 / 声明数 / 2 GB）两种策略下都抛错。
 */
public enum EntityOverflowPolicy <: Equatable<EntityOverflowPolicy> & ToString {
    /** 默认：软阈值超限后转溢出文件继续解析。 */
    | Spill
    /** 软阈值超限直接抛错。恶意样本固定使用它。 */
    | Strict

    public operator func ==(that: EntityOverflowPolicy): Bool {
        match ((this, that)) {
            case (Spill, Spill) => true
            case (Strict, Strict) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Spill => "Spill"
            case Strict => "Strict"
        }
    }
}

/**
 * 实体展开上限。计数器是**解析器实例级**的，不是全局状态。
 *
 * 默认值：单实体 64 KB、总量 8 MB、深度 16、声明数 1024、硬上限 2 GB。
 */
public struct EntityLimits {
    /** 单实体展开量软阈值。 */
    public let maxExpandedPerEntity: Int64

    /** 全文实体展开总量软阈值（不含原文）。 */
    public let maxExpandedTotal: Int64

    /** 实体递归深度硬限制。 */
    public let maxDepth: Int64

    /** 实体声明条数硬限制。 */
    public let maxDeclarations: Int64

    /** 展开总量硬限制。 */
    public let maxExpandedHardLimit: Int64

    /** 溢出文件目录；`None` 时按 TMPDIR → 系统临时目录 → `./.fountain_tmp` 解析。 */
    public let spillDir: ?Path

    public let overflowPolicy: EntityOverflowPolicy

    public init(
        maxExpandedPerEntity!: Int64 = 64 * 1024,
        maxExpandedTotal!: Int64 = 8 * 1024 * 1024,
        maxDepth!: Int64 = 16,
        maxDeclarations!: Int64 = 1024,
        maxExpandedHardLimit!: Int64 = 2 * 1024 * 1024 * 1024,
        spillDir!: ?Path = None,
        overflowPolicy!: EntityOverflowPolicy = EntityOverflowPolicy.Spill
    ) {
        this.maxExpandedPerEntity = maxExpandedPerEntity
        this.maxExpandedTotal = maxExpandedTotal
        this.maxDepth = maxDepth
        this.maxDeclarations = maxDeclarations
        this.maxExpandedHardLimit = maxExpandedHardLimit
        this.spillDir = spillDir
        this.overflowPolicy = overflowPolicy
    }
}

/** 解析选项。 */
public struct XmlParserOptions {
    /** 传给 `TextReader` / `BlockRuneSource` 的块大小。 */
    public let bufSize: Int64

    /** 是否丢弃元素之间「纯空白」产生的文本节点（`xml:space="preserve"` 强制保留）。 */
    public let trimWhitespaceOnly: Bool

    /** 实体展开上限。 */
    public let entityLimits: EntityLimits

    /** 字节序列不符合声明字符集时的策略。 */
    public let onInvalidByte: InvalidByteMode

    /** 元素嵌套深度上限。 */
    public let maxElementDepth: Int64

    /** 单个属性值（含实体展开结果）的长度上限。 */
    public let maxAttributeValueLength: Int64

    public init(
        bufSize!: Int64 = 8192,
        trimWhitespaceOnly!: Bool = false,
        entityLimits!: EntityLimits = EntityLimits(),
        onInvalidByte!: InvalidByteMode = InvalidByteMode.Strict,
        maxElementDepth!: Int64 = 4096,
        maxAttributeValueLength!: Int64 = 1024 * 1024
    ) {
        this.bufSize = bufSize
        this.trimWhitespaceOnly = trimWhitespaceOnly
        this.entityLimits = entityLimits
        this.onInvalidByte = onInvalidByte
        this.maxElementDepth = maxElementDepth
        this.maxAttributeValueLength = maxAttributeValueLength
    }
}
