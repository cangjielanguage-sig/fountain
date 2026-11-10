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
public class BlockRuneSource_test {
    /** UTF-16LE 的 U+0A00 低字节是 0x0A，不能当换行。 */
    @TestCase
    public func utf16ua000NotLineBreak(): Unit {
        let doc = "<a>\u{0A00}</a>"
        let source = BlockRuneSource(
            MemoryInputStream(utf16leBytes(doc)),
            codec: ByteCodec.Utf16Le,
            bufSize: 16
        )
        let text = drainRunes(source)
        assertTrue(text == doc, "实际为「${text}」")
        @Assert(text.runes().count() == doc.runes().count())
    }

    /** `bufSize = 16` 解析 4 KB UTF-16LE 文档无丢字。 */
    @TestCase
    public func smallBlocksAcrossLargeDocument(): Unit {
        let body = repeatText("中文测试😀abc", 200)
        let doc = "<r>${body}</r>"
        let source = BlockRuneSource(MemoryInputStream(utf16leBytes(doc)), codec: ByteCodec.Utf16Le, bufSize: 16)
        @Assert(drainRunes(source) == doc)
    }

    /** UTF-32BE 同理，块尾不完整字符回退到下一块。 */
    @TestCase
    public func utf32beAcrossBlocks(): Unit {
        let doc = "<r>中文😀</r>"
        let source = BlockRuneSource(MemoryInputStream(utf32beBytes(doc)), codec: ByteCodec.Utf32Be, bufSize: 12)
        @Assert(drainRunes(source) == doc)
    }

    /** 代理对跨块边界仍拼成一个码点（走块读入口路径）。 */
    @TestCase
    public func surrogatePairAcrossBlocks(): Unit {
        let doc = "a😀b"
        for (size in [4, 6, 8]) {
            let source = BlockRuneSource(MemoryInputStream(utf16leBytes(doc)), codec: ByteCodec.Utf16Le, bufSize: size)
            let text = drainWindow(LineWindow(source))
            assertTrue(text == doc, "bufSize=${size} 实际为「${text}」")
        }
    }

    /** UTF-16BE 基本路径。 */
    @TestCase
    public func utf16beBasic(): Unit {
        let doc = "<a>x</a>"
        let out = ArrayList<Byte>()
        for (r in doc.runes()) {
            let cp = r.position()
            out.add(UInt8((cp >> 8) & 0xFF))
            out.add(UInt8(cp & 0xFF))
        }
        let source = BlockRuneSource(MemoryInputStream(out.toArray()), codec: ByteCodec.Utf16Be, bufSize: 8)
        @Assert(drainRunes(source) == doc)
    }
}
