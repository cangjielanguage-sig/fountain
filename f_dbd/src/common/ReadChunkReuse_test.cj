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
package fountain::f_dbd.common

import std.env.getVariable
import std.io.InputStream
import std.runtime.{gc, getAllocatedHeapSize, getGCFreedSize}
import std.unittest.*
import std.unittest.testmacro.*

/** 固定字节流：一次 read 尽量填满调用方缓冲。 */
private class PatternStream <: InputStream {
    private let data: Array<Byte>
    private var pos = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= data.size || buffer.size == 0) {
            return 0
        }
        let left = data.size - pos
        let n = if (buffer.size < left) { buffer.size } else { left }
        data[pos..pos + n].copyTo(buffer, 0, 0, n)
        pos += n
        n
    }
}

/**
 * `readChunk` 的缓冲复用：单块缓冲跨轮复用后，输出仍按实际读取长度截断。
 */
@Test
public class ReadChunkReuse_test {

    @TestCase
    public func exactSizeCrossesBlocks(): Unit {
        let total: Int64 = 100 * 1024
        let data = patterned(total)
        let out = SqlTypes.readChunk(PatternStream(data), total)
        @Expect(out.size, total)
        @Expect(out[0], data[0])
        @Expect(out[total - 1], data[total - 1])
        @Expect(out[65536], data[65536])
    }

    @TestCase
    public func partialRequestStopsAtEof(): Unit {
        let data = patterned(10 * 1024)
        let out = SqlTypes.readChunk(PatternStream(data), 30 * 1024)
        @Expect(out.size, 10 * 1024)
        @Expect(out[out.size - 1], data[data.size - 1])
    }

    @TestCase
    public func emptyStreamReturnsEmpty(): Unit {
        @Expect(SqlTypes.readChunk(PatternStream(Array<Byte>()), 0).size, 0)
    }

    /** 记录 1 MiB「读至 EOF」的分配；只打印，不作硬门禁（GC 噪声不可控）。 */
    @TestCase
    public func benchToEnd(): Unit {
        if (!benchEnabled()) {
            println("DBD_READCHUNK_BENCH skipped (F_DBD_BENCH != 1)")
            return
        }
        let total: Int64 = 1024 * 1024
        let data = patterned(total)
        settle()
        let h0 = getAllocatedHeapSize()
        let f0 = getGCFreedSize()
        let out = SqlTypes.readChunk(PatternStream(data), 0)
        let alloc = (getAllocatedHeapSize() - h0) + (getGCFreedSize() - f0)
        @Expect(out.size, total)
        println("DBD_READCHUNK_BENCH payload=${total} alloc=${alloc}")
    }

    private func patterned(size: Int64): Array<Byte> {
        let bytes = Array<Byte>(size, repeat: 0)
        for (i in 0..size) {
            bytes[i] = UInt8(i % 251)
        }
        bytes
    }

    private func benchEnabled(): Bool {
        match (getVariable("F_DBD_BENCH")) {
            case Some(v) => v == "1"
            case None => false
        }
    }

    private func settle(): Unit {
        for (_ in 0..3) {
            gc()
        }
    }
}
