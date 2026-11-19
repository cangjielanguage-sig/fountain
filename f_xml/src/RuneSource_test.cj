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

import std.unittest.*
import std.unittest.testmacro.*
import std.time.MonoTime

@Test
public class RuneSource_test {
    /** 逐字符比较 `peek` / `peekFast`、`advance` / `advanceFast` 与行列号。 */
    private func assertFastParity(text: String, bufSize: Int64): Unit {
        let slow = Utf8RuneSource(MemoryInputStream(text), bufSize: bufSize)
        let fast = Utf8RuneSource(MemoryInputStream(text), bufSize: bufSize)
        while (true) {
            for (offset in 0..5) {
                let slowCp = match (slow.peek(offset)) {
                    case Some(r) => r.position()
                    case None => -1
                }
                assertTrue(
                    slowCp == fast.peekFast(offset),
                    "bufSize=${bufSize} offset=${offset} 前瞻不一致：${slowCp} vs ${fast.peekFast(offset)}"
                )
            }
            let slowPos = slow.position()
            let fastPos = fast.position()
            assertTrue(
                slowPos.line == fastPos.line && slowPos.column == fastPos.column,
                "bufSize=${bufSize} 位置不一致：(${slowPos.line},${slowPos.column}) vs (${fastPos.line},${fastPos.column})"
            )
            match (slow.advance()) {
                case Some(r) =>
                    assertTrue(fast.advanceFast() == r.position(), "bufSize=${bufSize} advance 不一致")
                case None =>
                    assertTrue(fast.advanceFast() < 0, "bufSize=${bufSize} EOF 不一致")
                    break
            }
        }
    }

    /** 两个版本在 4 / 8 / 16 / 8192 的块大小下逐字符一致。 */
    @TestCase
    public func fastAgreesWithOptionVersions(): Unit {
        let text = "<a x=\"中文\">😀\r\n tail</a>"
        for (size in [4, 8, 16, 8192]) {
            this.assertFastParity(text, size)
        }
    }

    /** 块边界上 `peekFast(0..4)` 仍然有效（前缀长度 62..66 覆盖 64 码点块的两侧）。 */
    @TestCase
    public func peekFastAcrossBlockBoundary(): Unit {
        for (prefix in [62, 63, 64, 65, 66]) {
            let text = repeatText("a", prefix) + "<bcd>"
            let source = Utf8RuneSource(MemoryInputStream(text), bufSize: 8)
            for (_ in 0..prefix) {
                @Assert(source.advanceFast() == r'a'.position())
            }
            let expected = [r'<', r'b', r'c', r'd', r'>']
            for (offset in 0..5) {
                assertTrue(
                    source.peekFast(offset) == expected[offset].position(),
                    "prefix=${prefix} offset=${offset} 期望 ${expected[offset].position()}，实际 ${source.peekFast(offset)}"
                )
            }
        }
    }

    /** 1 MB ASCII 文档确实按块解码：块填充次数与码点数成数量级差。 */
    @TestCase
    public func blocksAreFilledByBlock(): Unit {
        let text = repeatText("a", 1024 * 1024)
        let source = Utf8RuneSource(MemoryInputStream(text), bufSize: 8192)
        var count: Int64 = 0
        while (source.advanceFast() >= 0) {
            count++
        }
        assertTrue(count == 1024 * 1024, "码点数应为 1048576，实际 ${count}")
        assertTrue(source.codepointsYielded == count, "累计码点数应为 ${count}，实际 ${source.codepointsYielded}")
        assertTrue(
            source.blocksFilled <= count / 64 + 1,
            "块填充 ${source.blocksFilled} 次，超过 ${count} / 64 + 1"
        )
    }

    /** `peek` 不移动游标；连续两次结果相同。 */
    @TestCase
    public func peekDoesNotAdvance(): Unit {
        let source = Utf8RuneSource(MemoryInputStream("<a>"))
        let first = source.peek(1)
        let second = source.peek(1)
        @Assert(first == second)
        @Assert(match (first) {
            case Some(r) => r == r'a'
            case None => false
        })
        @Assert(match (source.advance()) {
            case Some(r) => r == r'<'
            case None => false
        })
    }

    /** 行列号 1-based：`<a>\n<b>` 消费到 `<b>` 的 `<` 时为 (2, 1)。 */
    @TestCase
    public func positionIsOneBased(): Unit {
        let source = Utf8RuneSource(MemoryInputStream("<a>\n<b>"))
        @Assert(source.position().line == 1 && source.position().column == 1)
        for (_ in 0..4) {
            source.advance()
        }
        let pos = source.position()
        assertTrue(pos.line == 2, "实际为 ${pos.line}")
        assertTrue(pos.column == 1, "实际为 ${pos.column}")
    }

    /** 初始位置恒为 (1, 1)。 */
    @TestCase
    public func initialPosition(): Unit {
        let source = Utf8RuneSource(MemoryInputStream("x"))
        @Assert(source.position().line == 1 && source.position().column == 1)
    }

    /** EOF 后 `advance` 一直返回 None。 */
    @TestCase
    public func eofIsSticky(): Unit {
        let source = Utf8RuneSource(MemoryInputStream("a"))
        @Assert(source.advance().isSome())
        @Assert(source.advance().isNone())
        @Assert(source.advance().isNone())
    }

    /** 4 字节 UTF-8 字符按一个码点读出。 */
    @TestCase
    public func fourByteRune(): Unit {
        let source = Utf8RuneSource(MemoryInputStream("😀"))
        @Assert(drainRunes(source) == "😀")
    }

    /** 主路径不分配第二份块：`LineWindow` 驱动时源的自有块始终为空。 */
    @TestCase
    public func lineWindowDoesNotAllocateSecondBlock(): Unit {
        let text = "<root><item id=\"1\">文本 😀</item></root>"
        let source = Utf8RuneSource(MemoryInputStream(text))
        let engine = ParserEngine(LineWindow(source), XmlParserOptions())
        while (engine.nextEvent().isSome()) {}
        @Assert(!source.hasOwnBlock())
        @Assert(source.blocksFilled > 0)
    }

    /**
     * 性能冒烟（**不设门禁**，只记录数值）：1 MB ASCII 文档走 `advanceFast` 的吞吐。
     *
     * 口径：`cjpm test` 用 cjc 默认的 `-O0` 构建（`compile-option` 未带 `-O2`），因此这里
     * 印出的是**未优化**吞吐；同一用例在 `-O2` 下实测 81 MB/s（1 MB / 12.3 ms），远高于
     * 20 MB/s 的目标值——说明 `decodeBlock` 确实走了 ASCII 批量搬运。两种口径都回填
     * `design.md` §7.3。
     */
    @TestCase
    public func advanceFastThroughputSmoke(): Unit {
        let megabytes: Int64 = 1
        let text = repeatText("a", megabytes * 1024 * 1024)
        let source = Utf8RuneSource(MemoryInputStream(text), bufSize: 8192)
        var count: Int64 = 0
        let start = MonoTime.now()
        while (source.advanceFast() >= 0) {
            count++
        }
        let ms = (MonoTime.now() - start) / Duration.millisecond
        let mib = Float64(megabytes)
        let throughput = if (ms <= 0.0) { -1.0 } else { mib * 1000.0 / ms }
        println("perf: advanceFast bytes=${count} ms=${ms} throughput_mb_s=${throughput} build=O0")
        assertTrue(count == megabytes * 1024 * 1024, "码点数应为 ${count}")
    }
}
