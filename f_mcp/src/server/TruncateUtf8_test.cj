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
package fountain::f_mcp.server

import std.collection.ArrayList
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private func repeatText(text: String, n: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..n) {
        sb.append(text)
    }
    sb.toString()
}

/** 改造前 `McpServer.truncateUtf8` 的同构副本：等价性 oracle，固化旧行为。 */
private func referenceTruncate(text: String, limit: Int64): String {
    if (limit <= 0) {
        return ''
    }
    let builder = StringBuilder()
    var used: Int64 = 0
    for (r in text.toRuneArray()) {
        let code = UInt32(r)
        let size: Int64 = if (code < 0x80) {
            1
        } else if (code < 0x800) {
            2
        } else if (code < 0x10000) {
            3
        } else {
            4
        }
        if (used + size > limit) {
            break
        }
        builder.append(r)
        used += size
    }
    builder.toString()
}

/** 结果必须是 `text` 按 rune 对齐的前缀：内容前缀 + 字节数上界 + 截断处不落在续字节上。 */
private func isRuneAlignedPrefix(text: String, cut: String, limit: Int64): Bool {
    if (!text.startsWith(cut)) {
        return false
    }
    if (cut.size > limit) {
        return false
    }
    if (cut.size < text.size) {
        let bytes = text.toArray()
        let next = bytes[cut.size]
        if ((next & 0xC0u8) == 0x80u8) {
            return false
        }
    }
    true
}

/** 强制 GC 并等计数稳定：`gc()` 可能异步收尾，紧接着的窗口会把这次 GC 记进去。 */
private func benchSettleGc(): Int64 {
    gc(heavy: true)
    var last = getGCCount()
    var stable = 0
    while (stable < 3) {
        sleep(Duration.millisecond * 5)
        let now = getGCCount()
        if (now == last) {
            stable++
        } else {
            stable = 0
            last = now
        }
    }
    last
}

/**
 * 单次调用的 (堆分配量, 耗时, 有效样本数) 中位数。
 *
 * `getAllocatedHeapSize()` 是「当前存活堆」，只读它会在窗口内发生 GC 时低估分配量，
 * 且大对象分配本身就会诱发 GC（`setGCThreshold` 对大对象无效）。因此按
 * `分配量 = 存活堆增量 + 期间释放量` 计算：进入窗口前先 `settleGc` 清空既有垃圾，
 * 于是窗口内的释放量只可能来自本次调用新产生的对象。分配量为 -1 表示无有效样本。
 */
private func measureCall(action: () -> String): (Int64, Int64, Int64) {
    let allocs = ArrayList<Int64>()
    let times = ArrayList<Int64>()
    var attempts = 0
    var sink = 0i64
    while (allocs.size < 5 && attempts < 12) {
        attempts++
        benchSettleGc()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        let start = MonoTime.now()
        sink += action().size
        let ns = (MonoTime.now() - start).toNanoseconds()
        let heap1 = getAllocatedHeapSize()
        let freed1 = getGCFreedSize()
        let alloc = (heap1 - heap0) + (freed1 - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
            times.add(ns)
        }
    }
    if (sink < 0) {
        return (-2, 0, allocs.size)
    }
    if (allocs.size == 0) {
        return (-1, 0, 0)
    }
    allocs.sort()
    times.sort()
    (allocs[allocs.size / 2], times[times.size / 2], allocs.size)
}

private func equivalenceCorpus(): ArrayList<String> {
    let corpus = ArrayList<String>()
    corpus.add('')
    corpus.add('a')
    corpus.add('abc')
    corpus.add('é')
    corpus.add('中')
    corpus.add('😀')
    corpus.add('aé中😀')
    corpus.add(repeatText('aé中😀', 3))
    corpus.add(repeatText('中', 4))
    corpus.add(repeatText('😀', 3))
    corpus.add(repeatText('abcd', 7))
    corpus
}

private func limitsFor(text: String): ArrayList<Int64> {
    let limits = ArrayList<Int64>()
    for (v in [0, 1, 2, 3, 4, 5, 7, 11]) {
        limits.add(v)
    }
    limits.add(text.size / 2)
    limits.add(text.size - 2)
    limits.add(text.size - 1)
    limits.add(text.size)
    limits.add(text.size + 1)
    limits
}

@Test
class TruncateUtf8_test {
    @TestCase
    public func equivalenceAcrossCorpus(): Unit {
        for (text in equivalenceCorpus()) {
            for (limit in limitsFor(text)) {
                let got = McpServer.truncateUtf8(text, limit)
                let want = referenceTruncate(text, limit)
                @Assert(want, got)
                if (limit > 0) {
                    @Assert(isRuneAlignedPrefix(text, got, limit))
                } else {
                    @Assert('', got)
                }
            }
        }
    }

    @TestCase
    public func equivalenceOnLargeText(): Unit {
        let cases = [
            ('ascii', repeatText('a', 1_048_576)),
            ('chinese', repeatText('中', 349_525)),
            ('emoji', repeatText('😀', 262_144))
        ]
        for ((label, text) in cases) {
            let limits = [3, 4, 5, text.size / 2, text.size - 1]
            for (limit in limits) {
                let got = McpServer.truncateUtf8(text, limit)
                let want = referenceTruncate(text, limit)
                @Assert(want, got)
                @Assert(got.size <= limit)
                println('EQUIV case=${label} bytes=${text.size} limit=${limit} cut=${got.size}')
            }
        }
    }

    @TestCase
    public func fastPathDoesNotCopy(): Unit {
        let text = repeatText('a', 1_048_576)
        @Assert(text, McpServer.truncateUtf8(text, text.size))
        @Assert(text, McpServer.truncateUtf8(text, text.size + 1_000))
        let atLimit = measureCall({ => McpServer.truncateUtf8(text, text.size) })
        let overLimit = measureCall({ => McpServer.truncateUtf8(text, text.size + 1_000) })
        println('FASTPATH bytes=${text.size} atLimitAlloc=${atLimit[0]} overLimitAlloc=${overLimit[0]} ' +
            'budget=${text.size / 16}')
        @Assert(atLimit[0] >= 0 && atLimit[0] < text.size / 16)
        @Assert(overLimit[0] >= 0 && overLimit[0] < text.size / 16)
    }

    @TestCase
    public func stopsAtFirstNonFittingRune(): Unit {
        let prefix = repeatText('a', 1_024)
        let text = prefix + repeatText('b', 1_048_576)
        let got = McpServer.truncateUtf8(text, prefix.size)
        @Assert(prefix, got)
        @Assert(got.size == prefix.size)
    }

    @TestCase
    public func zeroAndNegativeLimit(): Unit {
        let texts = ['abc', '中', '😀', 'aé中😀', repeatText('aé中😀', 3)]
        for (text in texts) {
            @Assert('', McpServer.truncateUtf8(text, 0))
            @Assert('', McpServer.truncateUtf8(text, -1))
            @Assert('', McpServer.truncateUtf8(text, -1_000))
        }
    }

    @TestCase
    public func keepsRuneBoundaryForMixedScript(): Unit {
        let text = repeatText('aé中😀', 5)
        var limit = 0i64
        while (limit <= text.size + 1) {
            let got = McpServer.truncateUtf8(text, limit)
            if (limit > 0) {
                @Assert(isRuneAlignedPrefix(text, got, limit))
                @Assert(got, String.fromUtf8(got.toArray()))
            }
            limit++
        }
    }

}
