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
import std.collection.ArrayList

@Test
public class InvalidByteMode_test {
    private func replaceSource(bytes: Array<Byte>, bufSize!: Int64 = 8192): Utf8RuneSource {
        Utf8RuneSource(MemoryInputStream(bytes), mode: InvalidByteMode.Replace, bufSize: bufSize)
    }

    private func concat(parts: Array<Array<Byte>>): Array<Byte> {
        let out = ArrayList<Byte>()
        for (part in parts) {
            for (b in part) {
                out.add(b)
            }
        }
        out.toArray()
    }

    private func countReplacement(text: String): Int64 {
        var n: Int64 = 0
        for (r in text.runes()) {
            if (r == r'\u{FFFD}') {
                n++
            }
        }
        n
    }

    /** Strict：坏字节抛 XmlException，消息带行列号与坏字节偏移。 */
    @TestCase
    public func strictRejectsInvalidByte(): Unit {
        let bytes: Array<Byte> = [0x61, 0xFF, 0x62]
        let source = Utf8RuneSource(MemoryInputStream(bytes), mode: InvalidByteMode.Strict)
        let error = assertXmlError({=> drainRunes(source)}, "字节偏移")
        @Assert(error.line == 1)
        @Assert(error.column == 2)
        @Assert(error.message.contains("第 1 行第 2 列"))
    }

    /** 合法输入下 Strict 与 Replace 逐字符一致。 */
    @TestCase
    public func legalInputAgrees(): Unit {
        let text = "<a>中文😀abc</a>"
        let strict = Utf8RuneSource(MemoryInputStream(text), mode: InvalidByteMode.Strict)
        let replace = replaceSource(text.toArray())
        @Assert(drainRunes(strict) == text)
        @Assert(drainRunes(replace) == text)
    }

    /** `E0 80` 只产出一个 U+FFFD，后续字符不错位。 */
    @TestCase
    public func singleReplacementForTruncatedSequence(): Unit {
        let bytes: Array<Byte> = [0x61, 0xE0, 0x80, 0x62]
        let text = drainRunes(replaceSource(bytes))
        assertTrue(countReplacement(text) == 1, "实际为「${text}」")
        assertTrue(text.runes().count() == 3, "实际长度 ${text.runes().count()}")
        let runes = runesOf(text)
        @Assert(runes[runes.size - 1] == r'b')
    }

    /** 三段坏序列各一个替换符，ASCII 位置不变。 */
    @TestCase
    public func onePerBrokenSegment(): Unit {
        let bytes: Array<Byte> = [0xE0, 0x80, 0x61, 0xF0, 0x80, 0x80, 0x62, 0xF5, 0x63]
        let text = drainRunes(replaceSource(bytes))
        assertTrue(countReplacement(text) == 3, "实际为「${text}」")
        assertTrue(text.runes().count() == 6, "实际长度 ${text.runes().count()}")
    }

    /** 块边界截断与块内截断结果一致。 */
    @TestCase
    public func blockBoundarySameAsWholeBuffer(): Unit {
        let bytes: Array<Byte> = [0x61, 0xE4, 0xB8, 0xAD, 0x62, 0xF0, 0x9F, 0x98, 0x80, 0x63]
        let whole = drainRunes(replaceSource(bytes, bufSize: 4096))
        for (size in [4, 5, 8]) {
            let split = drainRunes(replaceSource(bytes, bufSize: size))
            assertTrue(split == whole, "bufSize=${size} 时不一致：「${split}」vs「${whole}」")
        }
    }

    /** overlong（C0 AF）不崩溃，产出替换符。 */
    @TestCase
    public func overlongSequence(): Unit {
        let bytes: Array<Byte> = [0x61, 0xC0, 0xAF, 0x62]
        let text = drainRunes(replaceSource(bytes))
        @Assert(countReplacement(text) >= 1)
        @Assert(text.runes().first() == Some(r'a'))
        let runes = runesOf(text)
        @Assert(runes[runes.size - 1] == r'b')
    }

    /** 代理区（ED A0 80）产出替换符。 */
    @TestCase
    public func surrogateSequence(): Unit {
        let bytes: Array<Byte> = [0xED, 0xA0, 0x80, 0x21]
        let text = drainRunes(replaceSource(bytes))
        assertTrue(countReplacement(text) == 1, "实际为「${text}」")
        let runes = runesOf(text)
        @Assert(runes[runes.size - 1] == r'!')
    }

    /** 超出 U+10FFFF（F4 90 80 80）产出替换符。 */
    @TestCase
    public func outOfRangeSequence(): Unit {
        let bytes: Array<Byte> = [0xF4, 0x90, 0x80, 0x80, 0x21]
        let text = drainRunes(replaceSource(bytes))
        assertTrue(countReplacement(text) == 1, "实际为「${text}」")
        let runes = runesOf(text)
        @Assert(runes[runes.size - 1] == r'!')
    }

    /** Replace 产出的 U+FFFD 作为 1 个字符参与长度。 */
    @TestCase
    public func replacementCountsAsOneRune(): Unit {
        let text = drainRunes(replaceSource([0x61, 0xFF, 0x62]))
        assertTrue(text.toRuneArray().size == 3, "应为 3 个字符，实际 ${text.toRuneArray().size}")
        assertTrue(countReplacement(text) == 1, "应含 1 个 U+FFFD")
    }
}
