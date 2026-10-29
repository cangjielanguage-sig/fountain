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
public class RuneSource_test {
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
}
