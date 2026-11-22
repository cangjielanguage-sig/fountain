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
package fountain::f_data.json

import std.collection.ArrayList
import std.env.getVariable
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.StringGenerator

/** 旧式逐 rune 转义：仅用于基准对照，输出必须与 `escapeJsonString` 一致。 */
private func legacyEscape(s: String): String {
    let builder = StringGenerator()
    for (r in s.runes()) {
        if (r == r'"') {
            builder.append("\\\"")
        } else if (r == r'\\') {
            builder.append("\\\\")
        } else if (r == r'\n') {
            builder.append("\\n")
        } else if (r == r'\r') {
            builder.append("\\r")
        } else if (r == r'\t') {
            builder.append("\\t")
        } else if (r.position() < 0x20) {
            let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
            let cp = r.position()
            builder.append("\\u00")
            builder.append(digits[cp >> 4])
            builder.append(digits[cp & 0xF])
        } else {
            builder.append(r)
        }
    }
    builder.toString()
}

private func jsonBenchEnabled(): Bool {
    match (getVariable("F_DATA_JSON_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

private func jsonSettle(): Unit {
    for (_ in 0..3) {
        gc()
    }
}

private func jsonMeasure(action: () -> Unit): (Int64, Int64) {
    let allocs = ArrayList<Int64>()
    var attempts = 0
    while (allocs.size < 5 && attempts < 20) {
        attempts++
        jsonSettle()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        action()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
        }
    }
    if (allocs.size == 0) {
        return (-1, 0)
    }
    var best = allocs[0]
    for (a in allocs) {
        if (a < best) {
            best = a
        }
    }
    (best, allocs.size)
}

@Test
public class JsonEscapeFastPath_test {
    /** 无需转义的 ASCII：内容不变。 */
    @TestCase
    public func plainAsciiUnchanged(): Unit {
        @Assert("plain text 123", escapeJsonString("plain text 123"))
    }

    /** 中文与 emoji 不是转义字符。 */
    @TestCase
    public func cjkEmojiUnchanged(): Unit {
        @Assert("汉字😀", escapeJsonString("汉字😀"))
    }

    /** 空串返回空串。 */
    @TestCase
    public func emptyUnchanged(): Unit {
        @Assert("", escapeJsonString(""))
    }

    /** 双引号与反斜杠。 */
    @TestCase
    public func quoteAndBackslash(): Unit {
        @Assert("a\\\"b\\\\c", escapeJsonString("a\"b\\c"))
    }

    /** 换行、回车、制表与其它控制字符。 */
    @TestCase
    public func controlChars(): Unit {
        @Assert("a\\nb\\rc\\td\\u0001e", escapeJsonString("a\nb\rc\td\u{0001}e"))
    }

    /** 转义与非 ASCII 混合：非 ASCII 原样，特殊字符转义。 */
    @TestCase
    public func mixedNonAscii(): Unit {
        @Assert("中\\\"文😀\\n", escapeJsonString("中\"文😀\n"))
    }

    /** `DataString.toJsonString()` 的引号包裹与转义结果不变。 */
    @TestCase
    public func dataStringIntegration(): Unit {
        @Assert('"a\\\"b"', DataString('a"b').toJsonString())
        @Assert('"汉字😀"', DataString('汉字😀').toJsonString())
    }

    /** 快路径与旧式实现在所有输入上输出一致。 */
    @TestCase
    public func fastPathMatchesLegacy(): Unit {
        let samples = [
            "plain",
            "",
            "汉字😀",
            "a\"b\\c",
            "a\nb\rc\td",
            "中\"文😀\n",
            "\u{0001}\u{001F}\u{0020}"
        ]
        for (s in samples) {
            @Assert(legacyEscape(s), escapeJsonString(s))
        }
    }

    /**
     * 普通字符串转义基准：10000 次，快路径 `<= 128 B/次`，旧路径总量 > 快路径 8 倍。
     */
    @TestCase
    public func testBenchPlainEscapeAllocation(): Unit {
        if (!jsonBenchEnabled()) {
            println("SKIP: 未设置 F_DATA_JSON_BENCH=1，JSON 转义基准不执行")
            return
        }
        let ops: Int64 = 10000
        let small = "plain-ascii-字符串-0123456789"
        let acc = AtomicInt64(0)

        let (fastAlloc, fastSamples) = jsonMeasure({ =>
            for (_ in 0..ops) {
                acc.fetchAdd(escapeJsonString(small).size)
            }
        })
        let (legacyAlloc, legacySamples) = jsonMeasure({ =>
            for (_ in 0..ops) {
                acc.fetchAdd(legacyEscape(small).size)
            }
        })

        let fastPerCall = fastAlloc / ops
        println('JSON_ESCAPE_BENCH case=fast allocTotal=${fastAlloc} allocPerCall=${fastPerCall} ' +
            'samples=${fastSamples}')
        println('JSON_ESCAPE_BENCH case=legacy allocTotal=${legacyAlloc} ' +
            'allocPerCall=${legacyAlloc / ops} samples=${legacySamples}')
        @Assert(fastSamples > 0 && legacySamples > 0)
        @Assert(fastPerCall <= 128)
        @Assert(legacyAlloc > fastAlloc * 8)
    }
}
