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
package fountain::f_io

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.UnsafeBytes

/** 分隔符统一用 `\r\n--B`（5 B），便于把起始位置摆到半窗边界上。 */
private func sectionBoundary(): Array<Byte> {
    [0x0Du8, 0x0Au8, 0x2Du8, 0x2Du8, 0x42u8]
}

@Test
class RotatableBufferTest {
    /** 底层流读完后，read 必须返回 0，不能把窗口后半的零/旧字节当成数据。 */
    @TestCase
    func readStopsAtEof(): Unit {
        let input = ByteBuffer([1u8, 2u8, 3u8], toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8, 0xFEu8])
        let out = Array<Byte>(64, repeat: 0)

        let (first, _, _) = buffer.read(out)
        @Expect(first, 3)
        @Expect(out[0], 1u8)
        @Expect(out[1], 2u8)
        @Expect(out[2], 3u8)

        let (second, _, _) = buffer.read(out)
        @Expect(second, 0)
    }

    /** 空流首次 read 就是 0。 */
    @TestCase
    func emptyInputReturnsZero(): Unit {
        let input = ByteBuffer(Array<Byte>(0, repeat: 0), toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8])
        let out = Array<Byte>(16, repeat: 0)
        let (size, _, _) = buffer.read(out)
        @Expect(size, 0)
    }

    /** 恰好半窗的数据在 EOF 时只返回真实长度，第二读为 0。 */
    @TestCase
    func exactHalfWindowStopsAtEof(): Unit {
        let data = Array<Byte>(8, repeat: 7u8)
        let input = ByteBuffer(data, toOverwriteOnClearing: false)
        let buffer = RotatableBuffer(input, [0xFFu8], halfBufferSize: 8)
        let out = Array<Byte>(16, repeat: 0)
        let (first, _, _) = buffer.read(out)
        @Expect(first, 8)
        let (second, _, _) = buffer.read(out)
        @Expect(second, 0)
    }

    /** 读到 sectionEnd 当次只停住，不消费分隔符：offset 不动，indexOf 仍能找到分隔符。 */
    @TestCase
    func readStopsAtSectionEnd(): Unit {
        let payload = "ABC\r\n--B\r\nDEF"
        let buffer = RotatableBuffer(ByteBuffer(payload.unsafeBytes(), toOverwriteOnClearing: false), sectionBoundary())
        let out = Array<Byte>(8, repeat: 0)

        let (size, _, partEnd) = buffer.read(out)
        @Expect(size, 3)
        @Expect(partEnd, true)
        @Expect(buffer.offset, 3)
        @Expect(buffer.indexOf(sectionBoundary()), 3)
    }

    /** 下一次 read 才跳过分隔符，返回内容不含分隔符本身。 */
    @TestCase
    func nextReadSkipsSeparator(): Unit {
        let payload = "ABC\r\n--B\r\nDEF"
        let buffer = RotatableBuffer(ByteBuffer(payload.unsafeBytes(), toOverwriteOnClearing: false), sectionBoundary())
        let out = Array<Byte>(8, repeat: 0)

        let (first, _, _) = buffer.read(out)
        @Expect(first, 3)
        @Expect(buffer.offset, 3)

        let (second, _, _) = buffer.read(out)
        @Expect(second, 5)
        let expected: Array<Byte> = [0x0Du8, 0x0Au8, 0x44u8, 0x45u8, 0x46u8]
        for (i in 0..second) {
            @Expect(out[i], expected[i])
        }
    }

    /** 分隔符跨半窗：下一次 read 先旋转再跳过，返回下一段的字节。 */
    @TestCase
    func separatorAcrossHalfWindow(): Unit {
        let payload = "ABCDEFG\r\n--B\r\nHI"
        let buffer = RotatableBuffer(
            ByteBuffer(payload.unsafeBytes(), toOverwriteOnClearing: false),
            sectionBoundary(),
            halfBufferSize: 8
        )
        let out = Array<Byte>(8, repeat: 0)

        let (first, _, _) = buffer.read(out)
        @Expect(first, 7)
        @Expect(buffer.offset, 7)
        @Expect(buffer.indexOf(sectionBoundary()), 7)

        let (second, _, _) = buffer.read(out)
        @Expect(second, 4)
        let expected: Array<Byte> = [0x0Du8, 0x0Au8, 0x48u8, 0x49u8]
        for (i in 0..second) {
            @Expect(out[i], expected[i])
        }
    }

    /** 连续 3 个 section 顺序读取，最后读到 0。 */
    @TestCase
    func threeSectionsReadSequentially(): Unit {
        let payload = "A\r\n--B\r\nBB\r\n--B\r\nCCC"
        let buffer = RotatableBuffer(ByteBuffer(payload.unsafeBytes(), toOverwriteOnClearing: false), sectionBoundary())
        let out = Array<Byte>(8, repeat: 0)

        let (s1, _, _) = buffer.read(out)
        @Expect(s1, 1)
        @Expect(out[0], 0x41u8)
        @Expect(buffer.offset, 1)

        let (s2, _, _) = buffer.read(out)
        @Expect(s2, 4)
        let second: Array<Byte> = [0x0Du8, 0x0Au8, 0x42u8, 0x42u8]
        for (i in 0..s2) {
            @Expect(out[i], second[i])
        }

        let (s3, _, _) = buffer.read(out)
        @Expect(s3, 5)
        let third: Array<Byte> = [0x0Du8, 0x0Au8, 0x43u8, 0x43u8, 0x43u8]
        for (i in 0..s3) {
            @Expect(out[i], third[i])
        }

        let (s4, _, _) = buffer.read(out)
        @Expect(s4, 0)
    }
}
