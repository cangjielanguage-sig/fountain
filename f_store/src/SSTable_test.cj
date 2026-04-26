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

// ============================================================
// Step 9: SSTableReader 测试
// ============================================================

@Test
public class SSTableReaderTest {

    static func tempPath(testName: String): String {
        "/tmp/f_store_test/SSTableReader_${testName}.sst"
    }

    static func ensureDir(path: String): Unit {
        let dir = Path(path).parent
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    static func cleanFile(path: String): Unit {
        if (exists(Path(path))) {
            remove(path)
        }
    }

    /// 写入多条记录 → open → get 验证每条
    @TestCase
    public func sstableReaderGetAllEntries(): Unit {
        let path = tempPath("sstableReaderGetAllEntries")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        let k1 = ByteArray([0x01u8])
        let v1 = ByteArray([0x41u8])
        let k2 = ByteArray([0x02u8])
        let v2 = ByteArray([0x42u8])
        let k3 = ByteArray([0x03u8])
        let v3 = ByteArray([0x43u8])

        writer.write(k1, EntryValue(Some(v1.bytes), 10))
        writer.write(k2, EntryValue(Some(v2.bytes), 20))
        writer.write(k3, EntryValue(Some(v3.bytes), 30))
        writer.finish()

        let reader = SSTableReader.open(path)

        let r1 = reader.get(k1)
        @Expect(r1.isSome())
        if (let Some(e) <- r1) {
            @Expect(e.value == Some(v1.bytes))
            @Expect(e.sequence == 10)
        }

        let r2 = reader.get(k2)
        @Expect(r2.isSome())
        if (let Some(e) <- r2) {
            @Expect(e.value == Some(v2.bytes))
            @Expect(e.sequence == 20)
        }

        let r3 = reader.get(k3)
        @Expect(r3.isSome())
        if (let Some(e) <- r3) {
            @Expect(e.value == Some(v3.bytes))
            @Expect(e.sequence == 30)
        }

        reader.close()
        cleanFile(path)
    }

    /// get 不存在的 key 返回 None
    @TestCase
    public func sstableReaderGetMissingKey(): Unit {
        let path = tempPath("sstableReaderGetMissingKey")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 2))
        writer.finish()

        let reader = SSTableReader.open(path)
        let result = reader.get(ByteArray([0x02u8]))
        @Expect(result.isNone())

        // 远超范围的 key
        let result2 = reader.get(ByteArray([0xFFu8]))
        @Expect(result2.isNone())

        reader.close()
        cleanFile(path)
    }

    /// get tombstone 记录
    @TestCase
    public func sstableReaderGetTombstone(): Unit {
        let path = tempPath("sstableReaderGetTombstone")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        let key = ByteArray([0x01u8])
        writer.write(key, EntryValue(None, 5))
        writer.finish()

        let reader = SSTableReader.open(path)
        let result = reader.get(key)
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.value.isNone())
            @Expect(e.sequence == 5)
        }

        reader.close()
        cleanFile(path)
    }

    /// get 带 expireAt 的记录
    @TestCase
    public func sstableReaderGetWithExpireAt(): Unit {
        let path = tempPath("sstableReaderGetWithExpireAt")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        let key = ByteArray([0x01u8])
        let val = ByteArray([0x41u8])
        writer.write(key, EntryValue(Some(val.bytes), 1, expireAt: Some(999999)))
        writer.finish()

        let reader = SSTableReader.open(path)
        let result = reader.get(key)
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.expireAt == Some(999999))
        }

        reader.close()
        cleanFile(path)
    }

    /// iterator 全量有序遍历
    @TestCase
    public func sstableReaderIterator(): Unit {
        let path = tempPath("sstableReaderIterator")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        // 按序写入多条记录
        let keys = [ByteArray([0x01u8]), ByteArray([0x02u8]), ByteArray([0x03u8])]
        let vals = [ByteArray([0xA1u8]), ByteArray([0xA2u8]), ByteArray([0xA3u8])]
        writer.write(keys[0], EntryValue(Some(vals[0].bytes), 1))
        writer.write(keys[1], EntryValue(Some(vals[1].bytes), 2))
        writer.write(keys[2], EntryValue(Some(vals[2].bytes), 3))
        writer.finish()

        let reader = SSTableReader.open(path)
        let iter = reader.iterator()

        var count = 0
        var lastKey = ByteArray([])
        while (let Some((k, v)) <- iter.next()) {
            count++
            // 验证有序: 每个 key 大于等于前一个
            @Expect(k >= lastKey)
            lastKey = k
        }
        @Expect(count == 3)

        reader.close()
        cleanFile(path)
    }

    /// iterator 遍历含 tombstone 的记录
    @TestCase
    public func sstableReaderIteratorWithTombstone(): Unit {
        let path = tempPath("sstableReaderIteratorWithTombstone")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(None, 2))  // tombstone
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 3))
        writer.finish()

        let reader = SSTableReader.open(path)
        let iter = reader.iterator()

        var count = 0
        var tombstoneCount = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
            if (v.value.isNone()) {
                tombstoneCount++
            }
        }
        @Expect(count == 3)
        @Expect(tombstoneCount == 1)

        reader.close()
        cleanFile(path)
    }

    /// tailer 从指定 key 开始遍历
    @TestCase
    public func sstableReaderTailer(): Unit {
        let path = tempPath("sstableReaderTailer")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        writer.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 4))
        writer.finish()

        let reader = SSTableReader.open(path)
        let iter = reader.tailer(ByteArray([0x03u8]))

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
            // 从 0x03 开始，应该只遍历到 0x03 和 0x04
            @Expect(k >= ByteArray([0x03u8]))
        }
        @Expect(count == 2)

        reader.close()
        cleanFile(path)
    }

    /// 多 Data Block 下 get 正确
    @TestCase
    public func sstableReaderMultipleBlocks(): Unit {
        let path = tempPath("sstableReaderMultipleBlocks")
        cleanFile(path)
        ensureDir(path)

        // 写入足够多记录触发多个 Data Block（阈值 4KB）
        let writer = SSTableWriter(path, 100)
        let entryCount = 100
        for (i in 1..(entryCount + 1)) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let rawValue = Array<Byte>(64){_ => UInt8((i + 1).toUInt())}
            writer.write(ByteArray(rawKey), EntryValue(Some(rawValue), Int64(i)))
        }
        writer.finish()

        let reader = SSTableReader.open(path)
        // 验证每条记录都能读到
        for (i in 1..(entryCount + 1)) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let key = ByteArray(rawKey)
            let result = reader.get(key)
            @Expect(result.isSome())
            if (let Some(e) <- result) {
                @Expect(e.sequence == Int64(i))
            }
        }

        reader.close()
        cleanFile(path)
    }

    /// metadata 字段验证
    @TestCase
    public func sstableReaderMetadata(): Unit {
        let path = tempPath("sstableReaderMetadata")
        cleanFile(path)
        ensureDir(path)

        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 10))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 20))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 30))
        writer.finish()

        let reader = SSTableReader.open(path)
        let meta = reader.metadata
        @Expect(meta.entryCount == 3)

        reader.close()
        cleanFile(path)
    }
}

// ============================================================
// Step 10: SSTableFile 测试
// ============================================================

@Test
public class SSTableFileTest {

    static func tempDir(testName: String): String {
        "/tmp/f_store_test/SSTableFile_${testName}"
    }

    static func ensureDir(dir: String): Unit {
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    static func cleanDir(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    /// 创建 SSTableFile → get 验证
    @TestCase
    public func sstableFileGet(): Unit {
        let dir = tempDir("sstableFileGet")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_10.sst"
        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        let result = sstFile.get(ByteArray([0x01u8]))
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.sequence == 1)
        }

        let missing = sstFile.get(ByteArray([0xFFu8]))
        @Expect(missing.isNone())

        sstFile.close()
        cleanDir(dir)
    }

    /// close 后 isClosed 返回 true
    @TestCase
    public func sstableFileCloseAndIsClosed(): Unit {
        let dir = tempDir("sstableFileCloseAndIsClosed")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_5.sst"
        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        @Expect(!sstFile.isClosed())

        sstFile.close()
        @Expect(sstFile.isClosed())

        cleanDir(dir)
    }

    /// close 后 get 抛 StoreClosedException
    @TestCase
    public func sstableFileGetAfterCloseThrows(): Unit {
        let dir = tempDir("sstableFileGetAfterCloseThrows")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_5.sst"
        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        sstFile.close()

        var threw = false
        try {
            sstFile.get(ByteArray([0x01u8]))
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        cleanDir(dir)
    }

    /// 创建多个 SSTable → loadAll 加载 → get 验证
    @TestCase
    public func sstableFileLoadAll(): Unit {
        let dir = tempDir("sstableFileLoadAll")
        cleanDir(dir)
        ensureDir(dir)

        // 创建两个 sst 文件
        let path1 = "${dir}/L0_1_5.sst"
        let writer1 = SSTableWriter(path1, 10)
        writer1.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        writer1.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        writer1.finish()

        let path2 = "${dir}/L0_6_10.sst"
        let writer2 = SSTableWriter(path2, 10)
        writer2.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 6))
        writer2.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 7))
        writer2.finish()

        let files = SSTableFile.loadAll(dir)
        @Expect(files.size == 2)

        // 在所有文件中查找 key
        var found = false
        for (f in files) {
            let r = f.get(ByteArray([0x01u8]))
            if (r.isSome()) {
                found = true
                if (let Some(e) <- r) {
                    @Expect(e.sequence == 1)
                }
            }
        }
        @Expect(found)

        // 关闭所有文件
        for (f in files) {
            f.close()
        }

        cleanDir(dir)
    }

    /// loadAll 空目录
    @TestCase
    public func sstableFileLoadAllEmptyDir(): Unit {
        let dir = tempDir("sstableFileLoadAllEmptyDir")
        cleanDir(dir)
        ensureDir(dir)

        let files = SSTableFile.loadAll(dir)
        @Expect(files.size == 0)

        cleanDir(dir)
    }

    /// loadAll 目录不存在
    @TestCase
    public func sstableFileLoadAllNonExistDir(): Unit {
        let dir = tempDir("sstableFileLoadAllNonExistDir")
        cleanDir(dir)
        // 不创建目录

        let files = SSTableFile.loadAll(dir)
        @Expect(files.size == 0)
    }

    /// loadAll 跳过非 .sst 文件
    @TestCase
    public func sstableFileLoadAllSkipsNonSst(): Unit {
        let dir = tempDir("sstableFileLoadAllSkipsNonSst")
        cleanDir(dir)
        ensureDir(dir)

        // 创建一个 sst 文件
        let path1 = "${dir}/L0_1_5.sst"
        let writer1 = SSTableWriter(path1, 10)
        writer1.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer1.finish()

        // 创建一个非 sst 文件
        let junkPath = "${dir}/junk.txt"
        let junkFile = File(junkPath, OpenMode.ReadWrite)
        junkFile.write([0x00u8, 0x01u8])
        junkFile.flush()
        junkFile.close()

        let files = SSTableFile.loadAll(dir)
        @Expect(files.size == 1)

        for (f in files) {
            f.close()
        }

        cleanDir(dir)
    }

    /// parseFileName 正常文件名
    @TestCase
    public func sstableFileParseFileName(): Unit {
        let result = SSTableFile.parseFileName("L0_1_100.sst")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 0)
            @Expect(seqStart == 1)
            @Expect(seqEnd == 100)
        }
    }

    /// parseFileName 多层级
    @TestCase
    public func sstableFileParseFileNameLevel2(): Unit {
        let result = SSTableFile.parseFileName("L2_500_999.sst")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 2)
            @Expect(seqStart == 500)
            @Expect(seqEnd == 999)
        }
    }

    /// parseFileName 不含 .sst 后缀
    @TestCase
    public func sstableFileParseFileNameNoSuffix(): Unit {
        let result = SSTableFile.parseFileName("L0_1_100")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 0)
            @Expect(seqStart == 1)
            @Expect(seqEnd == 100)
        }
    }

    /// parseFileName 格式错误 — 不以 L 开头
    @TestCase
    public func sstableFileParseFileNameBadPrefix(): Unit {
        let result = SSTableFile.parseFileName("X0_1_100.sst")
        @Expect(result.isNone())
    }

    /// parseFileName 格式错误 — 部分 insufficient parts
    @TestCase
    public func sstableFileParseFileNameInsufficientParts(): Unit {
        let result = SSTableFile.parseFileName("L0_1.sst")
        @Expect(result.isNone())
    }

    /// parseFileName 格式错误 — 非数字
    @TestCase
    public func sstableFileParseFileNameNonNumeric(): Unit {
        let result = SSTableFile.parseFileName("L0_abc_100.sst")
        @Expect(result.isNone())
    }

    /// SSTableFile iterator 遍历
    @TestCase
    public func sstableFileIterator(): Unit {
        let dir = tempDir("sstableFileIterator")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_5.sst"
        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        let iter = sstFile.iterator()

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
        }
        @Expect(count == 3)

        sstFile.close()
        cleanDir(dir)
    }

    /// SSTableFile tailer 遍历
    @TestCase
    public func sstableFileTailer(): Unit {
        let dir = tempDir("sstableFileTailer")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_5.sst"
        let writer = SSTableWriter(path, 100)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        writer.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        writer.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 4))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        let iter = sstFile.tailer(ByteArray([0x03u8]))

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
            @Expect(k >= ByteArray([0x03u8]))
        }
        @Expect(count == 2)

        sstFile.close()
        cleanDir(dir)
    }

    /// SSTableFile.metadata 和 bloomFilter 便捷访问
    @TestCase
    public func sstableFileMetadataAccess(): Unit {
        let dir = tempDir("sstableFileMetadataAccess")
        cleanDir(dir)
        ensureDir(dir)

        let path = "${dir}/L0_1_5.sst"
        let writer = SSTableWriter(path, 10)
        writer.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        writer.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        writer.finish()

        let sstFile = SSTableFile.open(path)
        @Expect(sstFile.metadata.entryCount == 2)
        @Expect(sstFile.bloomFilter.n > 0)

        sstFile.close()
        cleanDir(dir)
    }
}
