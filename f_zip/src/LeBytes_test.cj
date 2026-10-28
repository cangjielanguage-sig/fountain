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
package fountain::f_zip

import fountain::f_io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class LeBytes_test {
    /** 场景「越界返回 None 且游标不位移」+「读越界后可继续读」。 */
    @TestCase
    public func outOfRangeKeepsCursor(): Unit {
        let buf = ByteBuffer([1u8, 2u8])
        let before = buf.readOffset
        @Assert(readU32LE(buf).isNone(), true)
        @Assert(buf.readOffset, before)
        // 越界之后仍能正常读到已有数据，说明失败没有污染游标
        @Assert(readU16LE(buf).getOrThrow(), 0x0201u16)
    }

    /** 场景「小端字节序确定」。 */
    @TestCase
    public func littleEndianBytes(): Unit {
        let out = ByteBuffer()
        writeU32LE(out, 0x04034b50)
        let bytes = out.bytes()
        @Assert(bytes.size, 4)
        @Assert(bytes[0], 0x50u8)
        @Assert(bytes[1], 0x4Bu8)
        @Assert(bytes[2], 0x03u8)
        @Assert(bytes[3], 0x04u8)

        let readBack = ByteBuffer(bytes)
        @Assert(readU32LE(readBack).getOrThrow(), 0x04034b50u32)
    }

    @TestCase
    public func u16AndU64RoundTrip(): Unit {
        let out = ByteBuffer()
        writeU16LE(out, 0xFFFF)
        writeU64LE(out, 0x0102030405060708)
        let buf = ByteBuffer(out.bytes())
        @Assert(readU16LE(buf).getOrThrow(), 0xFFFFu16)
        @Assert(readU64LE(buf).getOrThrow(), 0x0102030405060708u64)
    }

    /** 场景「校验实际读到的字节数」：定长读不足即失败，且不产生补零的假值。 */
    @TestCase
    public func shortReadReturnsNone(): Unit {
        let buf = ByteBuffer([1u8, 2u8, 3u8])
        @Assert(readBytes(buf, 5).isNone(), true)
        @Assert(buf.readOffset, 0)
        @Assert(readBytes(buf, 3).getOrThrow().size, 3)
        @Assert(readBytes(buf, 0).getOrThrow().size, 0)
    }

    @TestCase
    public func skipRespectsBounds(): Unit {
        let buf = ByteBuffer([1u8, 2u8, 3u8])
        @Assert(skipBytes(buf, 2), true)
        @Assert(buf.readOffset, 2)
        @Assert(skipBytes(buf, 2), false)
        @Assert(buf.readOffset, 2)
        @Assert(readU16LE(buf).isNone(), true)
    }
}
