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
public class LineWindow_test {
    private func window(text: String): LineWindow {
        LineWindow(Utf8RuneSource(MemoryInputStream(text)))
    }

    /** 行尾换行只出现一次；EOF 不补 `\n`。 */
    @TestCase
    public func singleTrailingNewline(): Unit {
        let text = drainWindow(window("<a>\n"))
        assertTrue(text == "<a>\n", "实际为「${text}」")
    }

    /** 空行（`\n\n`）产出两个换行，不会把 EOF 也算成空行。 */
    @TestCase
    public func emptyLineKept(): Unit {
        let text = drainWindow(window("<a>\n\n"))
        assertTrue(text == "<a>\n\n", "实际为「${text}」")
    }

    /** 孤立 `\r` 归一成 `\n`。 */
    @TestCase
    public func loneCrNormalized(): Unit {
        @Assert(drainWindow(window("<a>x\ry</a>")) == "<a>x\ny</a>")
    }

    /** `\r\n` 只归一一次。 */
    @TestCase
    public func crlfNormalizedOnce(): Unit {
        @Assert(drainWindow(window("<a>x\r\ny</a>")) == "<a>x\ny</a>")
    }

    /** 跨行 token 拼接：前瞻能跨过换行看到下一行内容。 */
    @TestCase
    public func peekAcrossLines(): Unit {
        let w = window("ab\ncd")
        w.advance()
        w.advance()
        let newline = w.peek(0)
        let next = w.peek(1)
        @Assert(match (newline) {
            case Some(r) => r == r'\n'
            case None => false
        })
        @Assert(match (next) {
            case Some(r) => r == r'c'
            case None => false
        })
    }

    /** 归一后的行列号：`\r\n` 只算一次换行。 */
    @TestCase
    public func positionAfterCrlf(): Unit {
        let w = window("a\r\nb")
        for (_ in 0..2) {
            w.advance()
        }
        let pos = w.position()
        assertTrue(pos.line == 2 && pos.column == 1, "实际为第 ${pos.line} 行第 ${pos.column} 列")
    }

    /** `\r` 落在块尾、`\n` 落在下一块时只归一一次（前缀 62..66 覆盖 64 码点块的两侧）。 */
    @TestCase
    public func crlfAcrossBlockBoundary(): Unit {
        for (size in [4, 8, 16, 64]) {
            for (prefix in 62..67) {
                let text = repeatText("a", prefix) + "\r\nb"
                let w = LineWindow(Utf8RuneSource(MemoryInputStream(text), bufSize: size))
                let expected = repeatText("a", prefix) + "\nb"
                let actual = drainWindow(w)
                assertTrue(actual == expected, "bufSize=${size} prefix=${prefix} 实际为「${actual}」")
            }
        }
    }

    /** `\r\r\n` 仍产出两个换行；跨块同样成立。 */
    @TestCase
    public func consecutiveCrProducesTwoNewlines(): Unit {
        for (size in [4, 8, 16, 64]) {
            for (prefix in [63, 64, 65]) {
                let text = repeatText("a", prefix) + "\r\r\nb"
                let w = LineWindow(Utf8RuneSource(MemoryInputStream(text), bufSize: size))
                let expected = repeatText("a", prefix) + "\n\nb"
                let actual = drainWindow(w)
                assertTrue(actual == expected, "bufSize=${size} prefix=${prefix} 实际为「${actual}」")
            }
        }
    }

    /** 位置只在消费时推进：填充（`peek` 跨块）不改变行列号。 */
    @TestCase
    public func positionMovesOnlyOnAdvance(): Unit {
        let w = window(repeatText("a", 64) + "\nb")
        @Assert(w.peek(4).isSome())
        let before = w.position()
        assertTrue(before.line == 1 && before.column == 1, "填充后位置不该变化")
        for (_ in 0..64) {
            w.advance()
        }
        @Assert(w.peek(1).isSome())
        let after = w.position()
        assertTrue(after.line == 1 && after.column == 65, "实际为第 ${after.line} 行第 ${after.column} 列")
        w.advance()
        let next = w.position()
        assertTrue(next.line == 2 && next.column == 1, "实际为第 ${next.line} 行第 ${next.column} 列")
    }

    /** 自定义 `RuneSource`（不继承 `BufferedRuneSource`）走逐字符回退路径，结果一致。 */
    @TestCase
    public func customSourceFallsBack(): Unit {
        let text = repeatText("a", 70) + "\r\n<b>x</b>"
        let expected = drainWindow(LineWindow(Utf8RuneSource(MemoryInputStream(text), bufSize: 4)))
        let actual = drainWindow(LineWindow(PlainRuneSource(text)))
        assertTrue(actual == expected, "回退路径结果不一致：「${actual}」vs「${expected}」")
    }
}

/** 只实现 `RuneSource` 五个方法、不继承 `BufferedRuneSource` 的最小源。 */
internal class PlainRuneSource <: RuneSource {
    private let cps: Array<Int64>
    private var pos: Int64 = 0
    private var line: Int64 = 1
    private var column: Int64 = 1

    init(text: String) {
        let out = ArrayList<Int64>()
        for (r in text.runes()) {
            out.add(r.position())
        }
        this.cps = out.toArray()
    }

    public func peekFast(offset: Int64): Int64 {
        let index = this.pos + offset
        if (offset < 0 || index >= this.cps.size) {
            return -1
        }
        this.cps[index]
    }

    public func advanceFast(): Int64 {
        if (this.pos >= this.cps.size) {
            return -1
        }
        let cp = this.cps[this.pos]
        this.pos++
        if (cp == 0x0A) {
            this.line++
            this.column = 1
        } else {
            this.column++
        }
        cp
    }

    public func peek(offset: Int64): ?Rune {
        let cp = this.peekFast(offset)
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func advance(): ?Rune {
        let cp = this.advanceFast()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func position(): SourcePosition {
        SourcePosition(this.line, this.column)
    }
}
