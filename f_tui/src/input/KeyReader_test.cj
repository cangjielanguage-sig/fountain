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
package fountain::f_tui.input

import fountain::f_tui.term.ByteSource
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

class FakeByteSource <: ByteSource {
    public var bytes: ArrayList<UInt8> = ArrayList<UInt8>()
    public var timeouts: ArrayList<Int64> = ArrayList<Int64>()

    public init(values: Array<UInt8>) {
        for (value in values) {
            bytes.add(value)
        }
    }

    public func read(timeoutMs: Int64): Option<UInt8> {
        timeouts.add(timeoutMs)
        if (bytes.isEmpty()) {
            None
        } else {
            Some(bytes.remove(at: 0))
        }
    }

    public func push(value: UInt8): Unit {
        bytes.add(value)
    }
}

func readAll(reader: KeyReader, limit: Int64): ArrayList<TerminalKey> {
    let keys = ArrayList<TerminalKey>()
    var i: Int64 = 0
    while (i < limit) {
        match (reader.readKey(10)) {
            case Some(key) => keys.add(key)
            case None => break
        }
        i += 1
    }
    keys
}

func utf8(value: String): Array<UInt8> {
    value.toArray()
}

@Test
public class KeyReader_test {
    /** 方向键、Tab 与 Shift+Tab 的表驱动用例。 */
    @TestCase
    public func navigationKeys(): Unit {
        let bytes: Array<UInt8> = [0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x42, 0x09, 0x1B, 0x5B, 0x5A]
        let reader = KeyReader(FakeByteSource(bytes))
        let keys = readAll(reader, 10)
        @Assert(keys.size, 4)
        @Assert(keys[0], TerminalKey.Up)
        @Assert(keys[1], TerminalKey.Down)
        @Assert(keys[2], TerminalKey.Tab)
        @Assert(keys[3], TerminalKey.BackTab)
    }

    /** q / r / a 落为 Char，由宿主决定语义。 */
    @TestCase
    public func plainCharacters(): Unit {
        let reader = KeyReader(FakeByteSource([0x71, 0x72, 0x61]))
        let keys = readAll(reader, 5)
        @Assert(keys.size, 3)
        @Assert(keys[0], TerminalKey.Char(r'q'))
        @Assert(keys[1], TerminalKey.Char(r'r'))
        @Assert(keys[2], TerminalKey.Char(r'a'))
    }

    /** 回车与独立 ESC。 */
    @TestCase
    public func enterAndEscape(): Unit {
        let reader = KeyReader(FakeByteSource([0x0D, 0x0A, 0x1B]))
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Enter)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Enter)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Escape)
        @Assert(reader.readKey(10).isNone())
    }

    /** 中文 UTF-8 解为单个字符，不按字节拆分。 */
    @TestCase
    public func utf8CharacterIsSingleKey(): Unit {
        let reader = KeyReader(FakeByteSource(utf8("中")))
        let key = reader.readKey(10).getOrThrow()
        @Assert(key, TerminalKey.Char(r'中'))
        @Assert(reader.readKey(10).isNone())
    }

    /** 两字节 UTF-8（é）同样解为一个字符。 */
    @TestCase
    public func twoByteUtf8(): Unit {
        let reader = KeyReader(FakeByteSource([0xC3, 0xA9]))
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Char(r'é'))
    }

    /** 拆包：ESC `[` 先到，后续 `A` 到达后拼成 Up。 */
    @TestCase
    public func splitEscapeSequenceKeepsPending(): Unit {
        let source = FakeByteSource([0x1B, 0x5B])
        let reader = KeyReader(source)
        @Assert(reader.readKey(10).isNone())
        @Assert(reader.pendingCount(), 2)

        source.push(0x41)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Up)
        @Assert(reader.pendingCount(), 0)
    }

    /** 拆包：UTF-8 多字节序列分两次到达。 */
    @TestCase
    public func splitUtf8KeepsPending(): Unit {
        let source = FakeByteSource([0xE4, 0xB8])
        let reader = KeyReader(source)
        @Assert(reader.readKey(10).isNone())
        @Assert(reader.pendingCount(), 2)

        source.push(0xAD)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Char(r'中'))
    }

    /** 未知 CSI 序列不会阻塞后续按键。 */
    @TestCase
    public func unknownSequenceIsSkipped(): Unit {
        let reader = KeyReader(FakeByteSource([0x1B, 0x5B, 0x35, 0x7E, 0x78]))
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Unknown)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Char(r'x'))
    }

    /** 控制字符统一落为 Unknown。 */
    @TestCase
    public func controlBytesAreUnknown(): Unit {
        let reader = KeyReader(FakeByteSource([0x01, 0x7F]))
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Unknown)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Unknown)
    }

    /** 没有可读字节时返回 None，不抛异常。 */
    @TestCase
    public func timeoutReturnsNone(): Unit {
        let reader = KeyReader(FakeByteSource([]))
        @Assert(reader.readKey(10).isNone())
    }

    /** 超时后保留未完成序列，下一次读取继续拼装。 */
    @TestCase
    public func timeoutPreservesIncompleteSequence(): Unit {
        let source = FakeByteSource([0x1B, 0x4F])
        let reader = KeyReader(source)
        @Assert(reader.readKey(10).isNone())
        @Assert(reader.pendingCount(), 2)

        source.push(0x42)
        @Assert(reader.readKey(10).getOrThrow(), TerminalKey.Down)
    }

    /** 解析器直接喂字节时，未完成序列保留、未知键不抛异常。 */
    @TestCase
    public func parserFeedsBytesIncrementally(): Unit {
        let parser = EscapeParser()
        parser.feed(0x1B)
        @Assert(parser.next().isNone())
        @Assert(parser.isLoneEscape())
        parser.feed(0x5B)
        @Assert(parser.next().isNone())
        parser.feed(0x41)
        @Assert(parser.next().getOrThrow(), TerminalKey.Up)
        @Assert(parser.pendingCount(), 0)
    }
}
