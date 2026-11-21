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
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `KnowledgeChunker` 的 local mode 分档契约。
 *
 * 覆盖三件事：门限常量与字节边界、`splitImpl` 的 local / 堆逐元素等价、
 * 公开 `split` 与堆基线一致。local 与堆两条路径都能被直接驱动，
 * 不依赖构造 2 MiB 大文档来观察档位。
 */
@Test
public class KnowledgeChunkerLocalModeTest {

    /** 门限常量：8 MiB 预算 ÷ 4 字节/Rune = 2 MiB 内容字节。 */
    @TestCase
    func testLocalBudgetConstants(): Unit {
        @Expect(KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES, 8 * 1024 * 1024)
        @Expect(KNOWLEDGE_CHUNKER_RUNE_BYTES, 4)
        @Expect(KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES, 2 * 1024 * 1024)
        @Expect(
            KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES,
            KNOWLEDGE_CHUNKER_LOCAL_BUDGET_BYTES / KNOWLEDGE_CHUNKER_RUNE_BYTES
        )
    }

    /** 字节级 predicate 的边界：0 / 1 / 2 MiB-1 / 2 MiB / 2 MiB+1 / Int64.Max。 */
    @TestCase
    func testBytesThresholdBoundaries(): Unit {
        @Expect(knowledgeChunkerUsesLocalBytes(0), false)
        @Expect(knowledgeChunkerUsesLocalBytes(1), true)
        // 699,050 个汉字 = 2,097,150 字节；699,051 个汉字 = 2,097,153 字节
        @Expect(knowledgeChunkerUsesLocalBytes(2_097_150), true)
        @Expect(knowledgeChunkerUsesLocalBytes(2_097_151), true)
        @Expect(knowledgeChunkerUsesLocalBytes(2_097_152), true)
        @Expect(knowledgeChunkerUsesLocalBytes(2_097_153), false)
        @Expect(knowledgeChunkerUsesLocalBytes(Int64.Max), false)
    }

    /** 字符串 wrapper：空串走堆早退，非空短串走 local。 */
    @TestCase
    func testStringThreshold(): Unit {
        @Expect(knowledgeChunkerUsesLocal(''), false)
        @Expect(knowledgeChunkerUsesLocal('abc'), true)
        @Expect(knowledgeChunkerUsesLocal('汉字'), true)
        @Expect(knowledgeChunkerUsesLocal('🙂'), true)
    }

    /** ASCII 内容 local / 堆逐元素等价。 */
    @TestCase
    func testAsciiEquivalent(): Unit {
        expectEquivalent('0123456789abcdefghijklmnopqrstuvwxyz', 4, 1)
    }

    /** 中文内容 local / 堆逐元素等价。 */
    @TestCase
    func testChineseEquivalent(): Unit {
        expectEquivalent('汉字检索记忆经验总结知识切块', 4, 1)
    }

    /** emoji 内容 local / 堆逐元素等价，且不切出半个字符。 */
    @TestCase
    func testEmojiEquivalent(): Unit {
        expectEquivalent('🙂🚀🔥✨🌙⭐🌈🎯', 2, 1)
    }

    /** 混合内容 local / 堆逐元素等价。 */
    @TestCase
    func testMixedEquivalent(): Unit {
        expectEquivalent('abc汉字🙂def记忆', 3, 1)
    }

    /** 单 rune、长度恰好等于 maxChars、overlap=0 的边界。 */
    @TestCase
    func testBoundaryShapesEquivalent(): Unit {
        expectEquivalent('a', 1, 0)
        expectEquivalent('汉字', 2, 0)
        expectEquivalent('01234567', 8, 0)
        expectEquivalent('汉字检索', 3, 2)
    }

    /** maxChars 1 / 2 / 4 / 400 与 overlap 0 / 1 / 50 的合法组合全部等价。 */
    @TestCase
    func testWindowAndOverlapMatrix(): Unit {
        let content = '0123456789abcdefghij汉字检索记忆经验总结'
        let maxCharsList = [1, 2, 4, 400]
        let overlapList = [0, 1, 50]
        for (maxChars in maxCharsList) {
            for (overlap in overlapList) {
                if (overlap >= maxChars) {
                    continue
                }
                expectEquivalent(content, maxChars, overlap)
            }
        }
    }

    /** 空内容在两条档位下都返回空列表。 */
    @TestCase
    func testEmptyContentBothModes(): Unit {
        @Expect(KnowledgeChunker.splitImpl('', 400, 50, true).size, 0)
        @Expect(KnowledgeChunker.splitImpl('', 400, 50, false).size, 0)
    }

    /** 公开 `split` 在门限以下与堆基线逐元素一致。 */
    @TestCase
    func testPublicSplitMatchesHeapBaseline(): Unit {
        let content = '知识文档切块与检索记忆经验总结'
        let actual = KnowledgeChunker.split(content, maxChars: 4, overlap: 1)
        let expected = KnowledgeChunker.splitImpl(content, 4, 1, false)
        expectSameChunks(actual, expected)
    }

    private func expectEquivalent(content: String, maxChars: Int64, overlap: Int64): Unit {
        let local = KnowledgeChunker.splitImpl(content, maxChars, overlap, true)
        let heap = KnowledgeChunker.splitImpl(content, maxChars, overlap, false)
        expectSameChunks(local, heap)
    }

    private func expectSameChunks(local: ArrayList<String>, heap: ArrayList<String>): Unit {
        @Expect(local.size, heap.size)
        for (index in 0..heap.size) {
            @Expect(local[index], heap[index])
        }
    }
}
