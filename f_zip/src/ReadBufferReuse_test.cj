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
import std.runtime.{gc, getAllocatedHeapSize, getGCFreedSize}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 读缓冲复用：`readAt` 与 `BoundedStream.read` 直接读入目标切片，不再按剩余长度整块中转。
 */
@Test
public class ReadBufferReuse_test {

    @TestCase
    public func readAtReadsDirectlyIntoDst(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let size: Int64 = 1024 * 1024
            let payload = patterned(size)
            let path = work.join("big.bin")
            File.writeTo(path, payload)
            let source = FileSource(path.toString())
            try {
                let dst = Array<Byte>(size, repeat: 0)
                @Expect(source.readAt(0, dst), size)  // 预热，排除首次读取的初始化
                settle()
                let h0 = getAllocatedHeapSize()
                let f0 = getGCFreedSize()
                let n = source.readAt(0, dst)
                let alloc = (getAllocatedHeapSize() - h0) + (getGCFreedSize() - f0)
                @Expect(n, size)
                @Expect(dst[0], payload[0])
                @Expect(dst[size - 1], payload[size - 1])
                println("ZIP_READAT_BENCH size=${size} alloc=${alloc}")
                @Expect(alloc < size / 4)
            } finally {
                source.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    @TestCase
    public func boundedStreamReadsDirectlyIntoDst(): Unit {
        let total: Int64 = 256 * 1024
        let payload = patterned(total)
        let stream = BoundedInputStream(ArrayRangeInputStream(payload, 0, total), total)
        let dst = Array<Byte>(512 * 1024, repeat: 0)
        settle()
        let h0 = getAllocatedHeapSize()
        let f0 = getGCFreedSize()
        let n = stream.read(dst)
        let alloc = (getAllocatedHeapSize() - h0) + (getGCFreedSize() - f0)
        @Expect(n, total)
        @Expect(dst[0], payload[0])
        @Expect(dst[total - 1], payload[total - 1])
        println("ZIP_BOUNDED_BENCH size=${total} alloc=${alloc}")
        @Expect(alloc < total / 4)
    }

    private func patterned(size: Int64): Array<Byte> {
        let bytes = Array<Byte>(size, repeat: 0)
        for (i in 0..size) {
            bytes[i] = UInt8(i % 251)
        }
        bytes
    }

    private func settle(): Unit {
        for (_ in 0..3) {
            gc()
        }
    }
}
