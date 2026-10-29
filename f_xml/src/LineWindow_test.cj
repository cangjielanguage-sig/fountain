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
}
