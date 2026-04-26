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
package fountain::f_store

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import fountain::f_base.*

@Test
public class SSTableTest {
    /// 构造临时 SSTable 文件路径
    static func tempPath(testName: String): String {
        "/tmp/f_store_test/SSTable_${testName}.sst"
    }

    /// 确保临时目录存在
    static func ensureDir(path: String): Unit {
        let dir = Path(path).parent
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    /// 删除临时文件
    static func cleanFile(path: String): Unit {
        if (exists(Path(path))) {
            remove(path)
        }
    }

    @TestCase
    public func sstableWriteAndFinish(): Unit {
        let path = tempPath("sstableWriteAndFinish")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        let k1 = ByteArray([0x01u8, 0x02u8])
        let v1 = ByteArray([0x41u8, 0x42u8])
        let k2 = ByteArray([0x03u8, 0x04u8])
        let v2 = ByteArray([0x43u8, 0x44u8])

        writer.write(k1, EntryValue(Some(v1.bytes), 1))
        writer.write(k2, EntryValue(Some(v2.bytes), 2))
        let metadata = writer.finish()

        // 验证文件存在且大小合理
        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 48)  // 至少 footer 大小
        @Expect(metadata.entryCount == 2)
        @Expect(metadata.sequenceStart == 1)
        @Expect(metadata.sequenceEnd == 2)

        cleanFile(path)
    }

    @TestCase
    public func sstableWriteTombstone(): Unit {
        let path = tempPath("sstableWriteTombstone")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 10)
        let key = ByteArray([0x01u8])

        // tombstone: value=None
        writer.write(key, EntryValue(None, 1))
        let metadata = writer.finish()

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 48)
        @Expect(metadata.entryCount == 1)

        cleanFile(path)
    }

    @TestCase
    public func sstableWriteAfterCloseThrows(): Unit {
        let path = tempPath("sstableWriteAfterCloseThrows")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.finish()

        var threw = false
        try {
            writer.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        cleanFile(path)
    }

    @TestCase
    public func sstableFinishIsIdempotent(): Unit {
        let path = tempPath("sstableFinishIsIdempotent")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        let meta1 = writer.finish()
        @Expect(meta1.entryCount == 1)

        // 第二次 finish 应该抛异常
        var threw = false
        try {
            writer.finish()
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        cleanFile(path)
    }

    @TestCase
    public func sstableIsFullSmallWrite(): Unit {
        let path = tempPath("sstableIsFullSmallWrite")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 3))

        // 小量写入，不应满
        @Expect(!writer.isFull())
        writer.finish()

        cleanFile(path)
    }

    @TestCase
    public func sstableMultipleBlocks(): Unit {
        let path = tempPath("sstableMultipleBlocks")
        cleanFile(path)
        ensureDir(path)

        // 写入多条数据，触发多个 Data Block（阈值 4KB）
        let writer = SSTableWriter(path, 100)
        for (i in 1..100) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let rawValue = Array<Byte>(64){_ => UInt8((i + 1).toUInt())}
            let key = ByteArray(rawKey)
            let value = ByteArray(rawValue)
            writer.write(key, EntryValue(Some(value.bytes), Int64(i)))
        }
        let metadata = writer.finish()

        @Expect(metadata.entryCount == 99)
        @Expect(metadata.sequenceStart == 1)
        @Expect(metadata.sequenceEnd == 99)

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        // 99 条记录，每条 8+64+32=104 字节 ≈ 10KB，加上 index/bloom/footer
        @Expect(size > 10240)

        cleanFile(path)
    }

    @TestCase
    public func sstableLargeValue(): Unit {
        let path = tempPath("sstableLargeValue")
        cleanFile(path)
        ensureDir(path)

        // 写入一条大 value
        let writer = SSTableWriter(path, 10)
        let largeKey = ByteArray([0xFFu8])
        let largeValue = Array<Byte>(4096){i => UInt8((i % 256).toUInt())}
        writer.write(largeKey, EntryValue(Some(largeValue), 1))
        let metadata = writer.finish()

        @Expect(metadata.entryCount == 1)

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 4096)

        cleanFile(path)
    }
}
