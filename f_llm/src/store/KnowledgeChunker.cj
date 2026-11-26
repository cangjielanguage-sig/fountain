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
package fountain::f_llm.store

import std.collection.*

/** 单次全文 rune 缓冲允许进入 local 分配的预算（字节）。 */
internal let KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES: Int64 = 8 * 1024 * 1024
/** `Rune` 的元素宽度（字节）。 */
internal let KNOWLEDGE_CHUNKER_RUNE_BYTES: Int64 = 4
/** 对应最坏情况 ASCII 的内容字节上限（8 MiB ÷ 4 字节/Rune = 2 MiB）。 */
internal let KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES: Int64 =
    KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES / KNOWLEDGE_CHUNKER_RUNE_BYTES

/** 按内容 UTF-8 字节数判断是否走 local 分配：空内容早退，超过门限走堆。 */
internal func knowledgeChunkerUsesLocalBytes(contentBytes: Int64): Bool {
    contentBytes > 0 && contentBytes <= KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES
}

/** 内容字节版门限判定的字符串入口。 */
internal func knowledgeChunkerUsesLocal(content: String): Bool {
    knowledgeChunkerUsesLocalBytes(content.size)
}

/**
 * 知识文档切块（P0）。
 *
 * 按**字符数**滑窗切分：`maxChars` 为窗口大小，`overlap` 为相邻窗口重叠，
 * 用于避免关键词正好落在切分边界。纯函数，便于单测；编码无关（不按字节）。
 */
public class KnowledgeChunker {
    public static const DEFAULT_MAX_CHARS = 400
    public static const DEFAULT_OVERLAP = 50

    private init() {
    }

    public static func split(content: String, maxChars!: Int64 = DEFAULT_MAX_CHARS, overlap!: Int64 = DEFAULT_OVERLAP): ArrayList<String> {
        if (maxChars <= 0) {
            throw IllegalArgumentException('maxChars must be positive, got ${maxChars}')
        }
        if (overlap < 0 || overlap >= maxChars) {
            throw IllegalArgumentException('overlap must be in [0, maxChars), got ${overlap} (maxChars=${maxChars})')
        }
        splitImpl(content, maxChars, overlap, knowledgeChunkerUsesLocal(content))
    }

    /**
     * 切块实现。`useLocal` 决定全文 rune 缓冲的分配档位：
     * local 档在函数返回时随 local region 整体释放，堆档与其他普通对象一致。
     * `chunks` / `StringBuilder` / chunk `String` 始终留在堆，不随档位切换。
     */
    internal static func splitImpl(content: String, maxChars: Int64, overlap: Int64, useLocal: Bool): ArrayList<String> {
        let chunks = ArrayList<String>()
        if (content.isEmpty()) {
            return chunks
        }
        // 先按 rune 展开：窗口与重叠都是「字符」，按字节切会把中文切坏并抛异常
        let total = countRunes(content)
        if (useLocal) {
            let runes = ArrayList<Rune>(total) @ local!
            for (rune in content.runes()) {
                runes.add(rune)
            }
            appendChunksLocal(runes, total, maxChars, overlap, chunks)
        } else {
            let runes = ArrayList<Rune>(total)
            for (rune in content.runes()) {
                runes.add(rune)
            }
            appendChunksHeap(runes, total, maxChars, overlap, chunks)
        }
        chunks
    }

    /**
     * local 档切块。
     *
     * 与 `appendChunksHeap` 的循环体相同，但必须分开：未优化（`-O0`）构建下，
     * 从 mode 化的 `ArrayList` 读元素会为每次访问在当前 local region 留下 32 字节
     * 临时对象，直到函数返回才释放。若两档共用 `@ local?` 变量，超过门限的堆路径
     * 也会为大文档消耗数百 MB local 并抛 `LocalRegionOutOfMemoryError`。
     * 生产 `-O2` 构建无此开销；分开后堆路径在任何构建档位都不碰 local region。
     * `exclave` 用于把外部 `@ local!` 的读操作留在调用者（`splitImpl`）的 region：
     * 非 exclave 的普通函数不能直接读外部 local! 元素。
     */
    private static exclave func appendChunksLocal(
        runes: ArrayList<Rune> @ local!,
        total: Int64,
        maxChars: Int64,
        overlap: Int64,
        chunks: ArrayList<String>
    ): Unit {
        let step = maxChars - overlap
        var start: Int64 = 0
        while (start < total) {
            let end = minOf(total, start + maxChars)
            let builder = StringBuilder()
            for (index in start..end) {
                builder.append(runes[index])
            }
            let piece = builder.toString()
            if (!piece.isEmpty()) {
                chunks.add(piece)
            }
            if (end >= total) {
                break
            }
            start += step
        }
    }

    /** 堆档切块；循环体与 `appendChunksLocal` 保持一致。 */
    private static func appendChunksHeap(
        runes: ArrayList<Rune>,
        total: Int64,
        maxChars: Int64,
        overlap: Int64,
        chunks: ArrayList<String>
    ): Unit {
        let step = maxChars - overlap
        var start: Int64 = 0
        while (start < total) {
            let end = minOf(total, start + maxChars)
            let builder = StringBuilder()
            for (index in start..end) {
                builder.append(runes[index])
            }
            let piece = builder.toString()
            if (!piece.isEmpty()) {
                chunks.add(piece)
            }
            if (end >= total) {
                break
            }
            start += step
        }
    }

    /** 只读扫描 rune 数，不分配；用于按精确容量构造缓冲，避免扩容顶破 8 MiB 预算。 */
    private static func countRunes(content: String): Int64 {
        var count: Int64 = 0
        for (_ in content.runes()) {
            count += 1
        }
        count
    }

    private static func minOf(a: Int64, b: Int64): Int64 {
        if (a < b) {
            a
        } else {
            b
        }
    }
}
