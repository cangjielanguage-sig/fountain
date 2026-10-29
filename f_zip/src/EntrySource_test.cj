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

import std.env
import std.fs.{Directory, File, removeIfExists}
import std.io.{ByteBuffer, InputStream}
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class EntrySource_test {
    /** 场景：`BufferSource` 的 size / readAt / openRange / close。 */
    @TestCase
    public func bufferSourceBasics(): Unit {
        let source = BufferSource([1u8, 2u8, 3u8, 4u8, 5u8])
        @Assert(source.size, 5)
        let dst = Array<Byte>(2, repeat: 0)
        @Assert(source.readAt(1, dst), 2)
        @Assert(dst[0], 2u8)
        @Assert(dst[1], 3u8)
        // 越界起点返回 0，不抛
        @Assert(source.readAt(9, dst), 0)
        source.close()
    }

    /** 场景：`openRange` 只返回指定窗口，且两个流互不干扰。 */
    @TestCase
    public func bufferSourceOpenRangeIsolated(): Unit {
        let source = BufferSource([10u8, 11u8, 12u8, 13u8, 14u8, 15u8])
        let a = source.openRange(0, 3)
        let b = source.openRange(3, 3)
        @Assert(a.read(Array<Byte>(2, repeat: 0)), 2)
        // b 的游标独立，仍在自己的窗口起点
        let buf = Array<Byte>(2, repeat: 0)
        @Assert(b.read(buf), 2)
        @Assert(buf[0], 13u8)
        @Assert(buf[1], 14u8)
    }

    /** 场景：`FileSource` 的 size / readAt / openRange 每次另开句柄。 */
    @TestCase
    public func fileSourceBasics(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("data.bin")
            File.writeTo(path, [1u8, 2u8, 3u8, 4u8, 5u8, 6u8])
            let source = FileSource(path.toString())
            @Assert(source.size, 6)
            let dst = Array<Byte>(3, repeat: 0)
            @Assert(source.readAt(2, dst), 3)
            @Assert(dst[0], 3u8)
            @Assert(dst[2], 5u8)

            let a = source.openRange(0, 2)
            let b = source.openRange(4, 2)
            let ba = Array<Byte>(2, repeat: 0)
            let bb = Array<Byte>(2, repeat: 0)
            @Assert(a.read(ba), 2)
            // 交替读：b 不受 a 的光标影响
            @Assert(b.read(bb), 2)
            @Assert(ba[0], 1u8)
            @Assert(bb[0], 5u8)
            source.close()
            @Assert(source.readAt(0, dst), 0)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

@Test
public class BoundedStream_test {
    /** 场景：限长 InputStream 到 EOF 返回 -1，且不多读一个字节。 */
    @TestCase
    public func boundedStreamStopsAtLimit(): Unit {
        let source = ByteBuffer([1u8, 2u8, 3u8, 4u8])
        let bounded = BoundedInputStream(source, 3)
        let buf = Array<Byte>(4, repeat: 0)
        @Assert(bounded.read(buf), 3)
        @Assert(bounded.read(buf), -1)
        // 底层还剩 1 字节，说明限长流没有越过边界
        @Assert(source.read(buf), 1)
        @Assert(buf[0], 4u8)
    }

    /** 场景：`Crc32InputStream` 统计原始字节数与 CRC。 */
    @TestCase
    public func crc32StreamCounts(): Unit {
        let data = "123456789".toArray()
        let stream = Crc32InputStream(ByteBuffer(data))
        var total: Int64 = 0
        let buf = Array<Byte>(4, repeat: 0)
        var n = stream.read(buf)
        while (n > 0) {
            total += n
            n = stream.read(buf)
        }
        @Assert(total, 9)
        @Assert(stream.count, 9)
        @Assert(stream.checksum(), 0xCBF43926u32)
    }
}
