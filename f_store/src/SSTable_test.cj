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

        let sst = SSTable(path, 100)
        let k1 = ByteArray([0x01u8, 0x02u8])
        let v1 = ByteArray([0x41u8, 0x42u8])
        let k2 = ByteArray([0x03u8, 0x04u8])
        let v2 = ByteArray([0x43u8, 0x44u8])

        sst.write(k1, EntryValue(Some(v1.bytes), 1))
        sst.write(k2, EntryValue(Some(v2.bytes), 2))
        let metadata = sst.finishWrite()

        // 验证文件存在且大小合理
        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 48)  // 至少 footer 大小
        @Expect(metadata.entryCount == 2)
        @Expect(metadata.sequenceStart == 1)
        @Expect(metadata.sequenceEnd == 2)

        // finishWrite 后可以立即 get（不需要重新打开）
        let r1 = sst.get(k1)
        @Expect(r1.isSome())
        if (let Some(e) <- r1) {
            @Expect(e.value == Some(v1.bytes))
            @Expect(e.sequence == 1)
        }

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableWriteTombstone(): Unit {
        let path = tempPath("sstableWriteTombstone")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        let key = ByteArray([0x01u8])

        // tombstone: value=None
        sst.write(key, EntryValue(None, 1))
        let metadata = sst.finishWrite()

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 48)
        @Expect(metadata.entryCount == 1)

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableWriteAfterFinishThrows(): Unit {
        let path = tempPath("sstableWriteAfterFinishThrows")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.finishWrite()

        var threw = false
        try {
            sst.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableFinishIsIdempotent(): Unit {
        let path = tempPath("sstableFinishIsIdempotent")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        let meta1 = sst.finishWrite()
        @Expect(meta1.entryCount == 1)

        // 第二次 finishWrite 应该抛异常
        var threw = false
        try {
            sst.finishWrite()
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableIsFullSmallWrite(): Unit {
        let path = tempPath("sstableIsFullSmallWrite")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 3))

        // 小量写入，不应满
        @Expect(!sst.isFull())
        sst.finishWrite()

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableWriteMultipleBlocks(): Unit {
        let path = tempPath("sstableWriteMultipleBlocks")
        cleanFile(path)
        ensureDir(path)

        // 写入多条数据，触发多个 Data Block（阈值 4KB）
        let sst = SSTable(path, 100)
        for (i in 1..100) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let rawValue = Array<Byte>(64){_ => UInt8((i + 1).toUInt())}
            let key = ByteArray(rawKey)
            let value = ByteArray(rawValue)
            sst.write(key, EntryValue(Some(value.bytes), Int64(i)))
        }
        let metadata = sst.finishWrite()

        @Expect(metadata.entryCount == 99)
        @Expect(metadata.sequenceStart == 1)
        @Expect(metadata.sequenceEnd == 99)

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        // 99 条记录，每条 8+64+32=104 字节 ≈ 10KB，加上 index/bloom/footer
        @Expect(size > 10240)

        sst.close()
        cleanFile(path)
    }

    @TestCase
    public func sstableLargeValue(): Unit {
        let path = tempPath("sstableLargeValue")
        cleanFile(path)
        ensureDir(path)

        // 写入一条大 value
        let sst = SSTable(path, 10)
        let largeKey = ByteArray([0xFFu8])
        let largeValue = Array<Byte>(4096){i => UInt8((i % 256).toUInt())}
        sst.write(largeKey, EntryValue(Some(largeValue), 1))
        let metadata = sst.finishWrite()

        @Expect(metadata.entryCount == 1)

        let file = File(path, OpenMode.Read)
        let size = file.info.size
        file.close()

        @Expect(size > 4096)

        sst.close()
        cleanFile(path)
    }

    /// finishWrite 后直接 get 验证（无需重新打开文件）
    @TestCase
    public func sstableGetAfterFinishWrite(): Unit {
        let path = tempPath("sstableGetAfterFinishWrite")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        let k1 = ByteArray([0x01u8])
        let v1 = ByteArray([0x41u8])
        let k2 = ByteArray([0x02u8])
        let v2 = ByteArray([0x42u8])
        let k3 = ByteArray([0x03u8])
        let v3 = ByteArray([0x43u8])

        sst.write(k1, EntryValue(Some(v1.bytes), 10))
        sst.write(k2, EntryValue(Some(v2.bytes), 20))
        sst.write(k3, EntryValue(Some(v3.bytes), 30))
        sst.finishWrite()

        // finishWrite 后直接 get，不需要 SSTable.open()
        let r1 = sst.get(k1)
        @Expect(r1.isSome())
        if (let Some(e) <- r1) {
            @Expect(e.value == Some(v1.bytes))
            @Expect(e.sequence == 10)
        }

        let r2 = sst.get(k2)
        @Expect(r2.isSome())
        if (let Some(e) <- r2) {
            @Expect(e.value == Some(v2.bytes))
            @Expect(e.sequence == 20)
        }

        let r3 = sst.get(k3)
        @Expect(r3.isSome())
        if (let Some(e) <- r3) {
            @Expect(e.value == Some(v3.bytes))
            @Expect(e.sequence == 30)
        }

        sst.close()
        cleanFile(path)
    }

    /// get 不存在的 key 返回 None
    @TestCase
    public func sstableGetMissingKey(): Unit {
        let path = tempPath("sstableGetMissingKey")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 2))
        sst.finishWrite()

        let result = sst.get(ByteArray([0x02u8]))
        @Expect(result.isNone())

        // 远超范围的 key
        let result2 = sst.get(ByteArray([0xFFu8]))
        @Expect(result2.isNone())

        sst.close()
        cleanFile(path)
    }

    /// get tombstone 记录
    @TestCase
    public func sstableGetTombstone(): Unit {
        let path = tempPath("sstableGetTombstone")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        let key = ByteArray([0x01u8])
        sst.write(key, EntryValue(None, 5))
        sst.finishWrite()

        let result = sst.get(key)
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.value.isNone())
            @Expect(e.sequence == 5)
        }

        sst.close()
        cleanFile(path)
    }

    /// get 带 expireAt 的记录
    @TestCase
    public func sstableGetWithExpireAt(): Unit {
        let path = tempPath("sstableGetWithExpireAt")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        let key = ByteArray([0x01u8])
        let val = ByteArray([0x41u8])
        sst.write(key, EntryValue(Some(val.bytes), 1, expireAt: Some(999999)))
        sst.finishWrite()

        let result = sst.get(key)
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.expireAt == Some(999999))
        }

        sst.close()
        cleanFile(path)
    }

    /// iterator 全量有序遍历
    @TestCase
    public func sstableIterator(): Unit {
        let path = tempPath("sstableIterator")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        // 按序写入多条记录
        let keys = [ByteArray([0x01u8]), ByteArray([0x02u8]), ByteArray([0x03u8])]
        let vals = [ByteArray([0xA1u8]), ByteArray([0xA2u8]), ByteArray([0xA3u8])]
        sst.write(keys[0], EntryValue(Some(vals[0].bytes), 1))
        sst.write(keys[1], EntryValue(Some(vals[1].bytes), 2))
        sst.write(keys[2], EntryValue(Some(vals[2].bytes), 3))
        sst.finishWrite()

        let iter = sst.iterator()

        var count = 0
        var lastKey = ByteArray([])
        while (let Some((k, v)) <- iter.next()) {
            count++
            // 验证有序: 每个 key 大于等于前一个
            @Expect(k >= lastKey)
            lastKey = k
        }
        @Expect(count == 3)

        sst.close()
        cleanFile(path)
    }

    /// iterator 遍历含 tombstone 的记录
    @TestCase
    public func sstableIteratorWithTombstone(): Unit {
        let path = tempPath("sstableIteratorWithTombstone")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(None, 2))  // tombstone
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 3))
        sst.finishWrite()

        let iter = sst.iterator()

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

        sst.close()
        cleanFile(path)
    }

    /// tailer 从指定 key 开始遍历
    @TestCase
    public func sstableTailer(): Unit {
        let path = tempPath("sstableTailer")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        sst.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 4))
        sst.finishWrite()

        let iter = sst.tailer(ByteArray([0x03u8]))

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
            // 从 0x03 开始，应该只遍历到 0x03 和 0x04
            @Expect(k >= ByteArray([0x03u8]))
        }
        @Expect(count == 2)

        sst.close()
        cleanFile(path)
    }

    /// 多 Data Block 下 get 正确
    @TestCase
    public func sstableMultipleBlocks(): Unit {
        let path = tempPath("sstableMultipleBlocks")
        cleanFile(path)
        ensureDir(path)

        // 写入足够多记录触发多个 Data Block（阈值 4KB）
        let sst = SSTable(path, 100)
        let entryCount = 100
        for (i in 1..(entryCount + 1)) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let rawValue = Array<Byte>(64){_ => UInt8((i + 1).toUInt())}
            sst.write(ByteArray(rawKey), EntryValue(Some(rawValue), Int64(i)))
        }
        sst.finishWrite()

        // 验证每条记录都能读到
        for (i in 1..(entryCount + 1)) {
            let rawKey = Array<Byte>(8){_ => UInt8(i.toUInt())}
            let key = ByteArray(rawKey)
            let result = sst.get(key)
            @Expect(result.isSome())
            if (let Some(e) <- result) {
                @Expect(e.sequence == Int64(i))
            }
        }

        sst.close()
        cleanFile(path)
    }

    /// metadata 字段验证
    @TestCase
    public func sstableMetadata(): Unit {
        let path = tempPath("sstableMetadata")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 10))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 20))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0x43u8]), 30))
        sst.finishWrite()

        let meta = sst.getMetadata()
        @Expect(meta.entryCount == 3)

        sst.close()
        cleanFile(path)
    }

    /// close 后 isClosed 返回 true
    @TestCase
    public func sstableCloseAndIsClosed(): Unit {
        let path = tempPath("sstableCloseAndIsClosed")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.finishWrite()

        @Expect(!sst.isClosed())
        sst.close()
        @Expect(sst.isClosed())

        cleanFile(path)
    }

    /// close 后 get 抛 StoreClosedException
    @TestCase
    public func sstableGetAfterCloseThrows(): Unit {
        let path = tempPath("sstableGetAfterCloseThrows")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.finishWrite()
        sst.close()

        var threw = false
        try {
            sst.get(ByteArray([0x01u8]))
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        cleanFile(path)
    }

    /// 从已有文件 open → get 验证
    @TestCase
    public func sstableOpenAndGet(): Unit {
        let dir = "/tmp/f_store_test/SSTable_open_get"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_10.sst"
        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        sst.finishWrite()
        sst.close()

        // 重新打开
        let sst2 = SSTable.open(path)
        let result = sst2.get(ByteArray([0x01u8]))
        @Expect(result.isSome())
        if (let Some(e) <- result) {
            @Expect(e.sequence == 1)
        }

        let missing = sst2.get(ByteArray([0xFFu8]))
        @Expect(missing.isNone())

        sst2.close()
        remove(dir, recursive: true)
    }

    /// loadAll 加载多个 SSTable
    @TestCase
    public func sstableLoadAll(): Unit {
        let dir = "/tmp/f_store_test/SSTable_loadAll"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建两个 sst 文件
        let path1 = "${dir}/L0_1_5.sst"
        let sst1 = SSTable(path1, 10)
        sst1.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        sst1.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        sst1.finishWrite()
        sst1.close()

        let path2 = "${dir}/L0_6_10.sst"
        let sst2 = SSTable(path2, 10)
        sst2.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 6))
        sst2.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 7))
        sst2.finishWrite()
        sst2.close()

        let files = SSTable.loadAll(dir)
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

        remove(dir, recursive: true)
    }

    /// loadAll 空目录
    @TestCase
    public func sstableLoadAllEmptyDir(): Unit {
        let dir = "/tmp/f_store_test/SSTable_loadAllEmpty"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let files = SSTable.loadAll(dir)
        @Expect(files.size == 0)

        remove(dir, recursive: true)
    }

    /// loadAll 目录不存在
    @TestCase
    public func sstableLoadAllNonExistDir(): Unit {
        let dir = "/tmp/f_store_test/SSTable_loadAllNonExist"
        let files = SSTable.loadAll(dir)
        @Expect(files.size == 0)
    }

    /// loadAll 跳过非 .sst 文件
    @TestCase
    public func sstableLoadAllSkipsNonSst(): Unit {
        let dir = "/tmp/f_store_test/SSTable_loadAllSkip"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建一个 sst 文件
        let path1 = "${dir}/L0_1_5.sst"
        let sst1 = SSTable(path1, 10)
        sst1.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst1.finishWrite()
        sst1.close()

        // 创建一个非 sst 文件
        let junkPath = "${dir}/junk.txt"
        let junkFile = File(junkPath, OpenMode.ReadWrite)
        junkFile.write([0x00u8, 0x01u8])
        junkFile.flush()
        junkFile.close()

        let files = SSTable.loadAll(dir)
        @Expect(files.size == 1)

        for (f in files) {
            f.close()
        }

        remove(dir, recursive: true)
    }

    /// parseFileName 正常文件名
    @TestCase
    public func sstableParseFileName(): Unit {
        let result = SSTable.parseFileName("L0_1_100.sst")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 0)
            @Expect(seqStart == 1)
            @Expect(seqEnd == 100)
        }
    }

    /// parseFileName 多层级
    @TestCase
    public func sstableParseFileNameLevel2(): Unit {
        let result = SSTable.parseFileName("L2_500_999.sst")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 2)
            @Expect(seqStart == 500)
            @Expect(seqEnd == 999)
        }
    }

    /// parseFileName 不含 .sst 后缀
    @TestCase
    public func sstableParseFileNameNoSuffix(): Unit {
        let result = SSTable.parseFileName("L0_1_100")
        @Expect(result.isSome())
        if (let Some((level, seqStart, seqEnd)) <- result) {
            @Expect(level == 0)
            @Expect(seqStart == 1)
            @Expect(seqEnd == 100)
        }
    }

    /// parseFileName 格式错误 — 不以 L 开头
    @TestCase
    public func sstableParseFileNameBadPrefix(): Unit {
        let result = SSTable.parseFileName("X0_1_100.sst")
        @Expect(result.isNone())
    }

    /// parseFileName 格式错误 — 部分 insufficient parts
    @TestCase
    public func sstableParseFileNameInsufficientParts(): Unit {
        let result = SSTable.parseFileName("L0_1.sst")
        @Expect(result.isNone())
    }

    /// parseFileName 格式错误 — 非数字
    @TestCase
    public func sstableParseFileNameNonNumeric(): Unit {
        let result = SSTable.parseFileName("L0_abc_100.sst")
        @Expect(result.isNone())
    }

    /// iterator 遍历
    @TestCase
    public func sstableIteratorFromOpen(): Unit {
        let dir = "/tmp/f_store_test/SSTable_iter_open"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_5.sst"
        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        sst.finishWrite()
        sst.close()

        let sst2 = SSTable.open(path)
        let iter = sst2.iterator()

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
        }
        @Expect(count == 3)

        sst2.close()
        remove(dir, recursive: true)
    }

    /// tailer 遍历
    @TestCase
    public func sstableTailerFromOpen(): Unit {
        let dir = "/tmp/f_store_test/SSTable_tailer_open"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_5.sst"
        let sst = SSTable(path, 100)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0xA1u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0xA2u8]), 2))
        sst.write(ByteArray([0x03u8]), EntryValue(Some([0xA3u8]), 3))
        sst.write(ByteArray([0x04u8]), EntryValue(Some([0xA4u8]), 4))
        sst.finishWrite()
        sst.close()

        let sst2 = SSTable.open(path)
        let iter = sst2.tailer(ByteArray([0x03u8]))

        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
            @Expect(k >= ByteArray([0x03u8]))
        }
        @Expect(count == 2)

        sst2.close()
        remove(dir, recursive: true)
    }

    /// metadata 和 bloomFilter 便捷访问
    @TestCase
    public func sstableMetadataAndBloomAccess(): Unit {
        let dir = "/tmp/f_store_test/SSTable_meta_bloom"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_5.sst"
        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01u8]), EntryValue(Some([0x41u8]), 1))
        sst.write(ByteArray([0x02u8]), EntryValue(Some([0x42u8]), 2))
        sst.finishWrite()

        @Expect(sst.getMetadata().entryCount == 2)
        @Expect(sst.getBloomFilter().n > 0)

        sst.close()
        remove(dir, recursive: true)
    }

    /// Step 18: BloomFilter 序列化 — finishWrite 后 mightContain 正确
    @TestCase
    public func sstableBloomFilterAfterFinish(): Unit {
        let path = tempPath("sstableBloomFilterAfterFinish")
        cleanFile(path)
        ensureDir(path)

        let sst = SSTable(path, 100)
        let k1 = ByteArray([0x01u8, 0x02u8])
        let k2 = ByteArray([0x03u8, 0x04u8])
        let k3 = ByteArray([0x05u8, 0x06u8])

        sst.write(k1, EntryValue(Some([0x41u8]), 1))
        sst.write(k2, EntryValue(Some([0x42u8]), 2))
        sst.write(k3, EntryValue(Some([0x43u8]), 3))
        sst.finishWrite()

        let bf = sst.getBloomFilter()
        @Expect(bf.n > 0)
        // 写入的 key 应该被 BloomFilter 识别
        @Expect(bf.mightContain(k1.bytes))
        @Expect(bf.mightContain(k2.bytes))
        @Expect(bf.mightContain(k3.bytes))

        sst.close()
        cleanFile(path)
    }

    /// Step 18: BloomFilter 序列化 — open 后反序列化正确
    @TestCase
    public func sstableBloomFilterAfterOpen(): Unit {
        let dir = "/tmp/f_store_test/SSTable_bloom_open"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_10.sst"
        let sst = SSTable(path, 100)
        let k1 = ByteArray([0x0Au8, 0x0Bu8])
        let k2 = ByteArray([0x0Cu8, 0x0Du8])
        let k3 = ByteArray([0x0Eu8, 0x0Fu8])

        sst.write(k1, EntryValue(Some([0xA1u8]), 1))
        sst.write(k2, EntryValue(Some([0xA2u8]), 2))
        sst.write(k3, EntryValue(Some([0xA3u8]), 3))
        sst.finishWrite()
        sst.close()

        // 重新打开，BloomFilter 需从序列化数据反序列化
        let sst2 = SSTable.open(path)
        let bf = sst2.getBloomFilter()
        @Expect(bf.n > 0)
        @Expect(bf.mightContain(k1.bytes))
        @Expect(bf.mightContain(k2.bytes))
        @Expect(bf.mightContain(k3.bytes))

        // 未写入的 key 大概率不在（允许误判，但不应该有假阴性）
        let missing = ByteArray([0xFFu8, 0xFFu8])
        let r = sst2.get(missing)
        if (r.isNone()) {
            // 确实不存在时，BloomFilter 也大概率返回 false
            // （这里不强制断言，因为 BloomFilter 有误判率）
        }

        sst2.close()
        remove(dir, recursive: true)
    }

    /// Step 18+: BloomFilter FPR — 误判率在校验范围内（≤配置的 1%）
    @TestCase
    public func sstableBloomFilterFPR(): Unit {
        let dir = "/tmp/f_store_test/SSTable_bloom_fpr"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_1000.sst"
        let totalKeys: Int64 = 500
        let testMisses: Int64 = 500
        let sst = SSTable(path, totalKeys + testMisses)
        // 写入 known keys（使用固定前缀避免与测试 miss keys 冲突）
        for (i in 1..=totalKeys) {
            let key = makeKey(i, 0xAAu8)
            sst.write(key, EntryValue(Some([0x01u8]), i))
        }
        sst.finishWrite()

        let bf = sst.getBloomFilter()
        @Expect(bf.n > 0)

        // 测试未写入的 keys，统计误判数
        var falsePositives: Int64 = 0
        for (i in 1..=testMisses) {
            let missKey = makeKey(i, 0xFFu8)
            if (bf.mightContain(missKey.bytes)) {
                falsePositives += 1
            }
        }

        // 期望误判率 ≤ 5%（配置为 1%，宽松上限）
        let fpr = Float64(falsePositives) / Float64(testMisses)
        @Expect(fpr <= 0.05)

        sst.close()
        remove(dir, recursive: true)
    }

    /// Step 18+: BloomFilter 否定查询 — get() 对不存在 key 返回 None（走 BloomFilter 快速路径）
    @TestCase
    public func sstableBloomFilterNegativeQuery(): Unit {
        let dir = "/tmp/f_store_test/SSTable_bloom_neg"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1_200.sst"
        let sst = SSTable(path, 200)
        // 写入 100 keys
        for (i in 1..=100) {
            let key = ByteArray([UInt8(i), 0x01u8])
            sst.write(key, EntryValue(Some([0x01u8]), Int64(i)))
        }
        sst.finishWrite()

        // 关闭后重新打开，验证 BloomFilter 反序列化后仍有效
        sst.close()
        let sst2 = SSTable.open(path)

        // 查询 100 个不存在的 key，全部应返回 None
        for (i in 1..=100) {
            let missKey = ByteArray([UInt8(100 + i), 0x01u8])
            let result = sst2.get(missKey)
            @Expect(result.isNone())
        }

        sst2.close()
        remove(dir, recursive: true)
    }

    /// 辅助：构造带前缀的 key（3 字节: prefix + index 高8位 + index 低8位）
    private static func makeKey(index: Int64, prefix: UInt8): ByteArray {
        ByteArray([prefix, UInt8(index / 256), UInt8(index % 256)])
    }

    /// Step 18+: BloomFilter 空表 — 0 条数据时行为正确
    @TestCase
    public func sstableBloomFilterEmpty(): Unit {
        let dir = "/tmp/f_store_test/SSTable_bloom_empty"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_0_0.sst"
        let sst = SSTable(path, 10)
        sst.finishWrite()

        let bf = sst.getBloomFilter()
        // 空表的 BloomFilter 对所有 key 都应返回 false
        @Expect(!bf.mightContain(ByteArray([0x01u8]).bytes))
        @Expect(!bf.mightContain(ByteArray([0xFFu8, 0xFFu8]).bytes))

        // SSTable.get() 也应返回 None
        @Expect(sst.get(ByteArray([0x01u8])).isNone())

        sst.close()
        remove(dir, recursive: true)
    }

    /** 0 条 entry 后 finishWrite 不崩溃 */
    @TestCase
    public func sstableZeroEntriesFinishNoCrash(): Unit {
        let dir = "/tmp/f_store_sst_empty_finish"
        if (!exists(dir)) { Directory.create(dir, recursive: true) }
        let path = "${dir}/empty.sst"
        let sst = SSTable(path, 1)
        // 不写入任何 entry，直接 finishWrite
        let meta = sst.finishWrite()
        @Expect(meta.entryCount == 0)
        // 对空 SSTable 做 get 应返回 None
        @Expect(sst.get(ByteArray([0x01])).isNone())
        // iterator 应返回 0 条
        var iterCount: Int64 = 0
        let iter = sst.iterator()
        while (let Some(_) <- iter.next()) {
            iterCount++
        }
        @Expect(iterCount == 0)
        sst.close()
        remove(dir, recursive: true)
    }

    /** 多线程并发 get 同一 SSTable，验证无竞争数据损坏 */
    @TestCase
    public func sstableConcurrentGetNoRace(): Unit {
        let dir = "/tmp/f_store_test/SSTable_conc_get"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let path = "${dir}/test.sst"

        // 创建包含 500 条记录的 SSTable（多 Data Block）
        let sst = SSTable(path, 500)
        let n: Int64 = 500
        for (i in 0..n) {
            let key = ByteArray([UInt8((i / 256) % 256), UInt8(i % 256)])
            sst.write(key, EntryValue([UInt8(i % 256)], i))
        }
        sst.finishWrite()

        // 4 线程并发 get，每个线程读取所有 key
        let threadCount = 4
        let futures = ArrayList<Future<Int64>>()
        for (t in 0..threadCount) {
            let fut = spawn {
                var errors: Int64 = 0
                for (i in 0..n) {
                    let key = ByteArray([UInt8((i / 256) % 256), UInt8(i % 256)])
                    let result = sst.get(key)
                    if (result.isNone()) {
                        errors++
                    } else if (let Some(e) <- result) {
                        // 验证 sequence 匹配
                        if (e.sequence != i) {
                            errors++
                        }
                    }
                }
                errors
            }
            futures.add(fut)
        }

        // 收集结果
        var totalErrors: Int64 = 0
        for (fut in futures) {
            totalErrors += fut.get()
        }
        @Expect(totalErrors == 0)

        sst.close()
        remove(dir, recursive: true)
    }

    /** 验证 openFromFile 从文件名正确解析 level（P0-1 修复验证）。
     *  旧版硬编码 level=0，修复后从 L{level}_{sstIndex}.sst 解析。 */
    @TestCase
    public func sstableOpenFromFileParsesLevelFromName(): Unit {
        let dir = "/tmp/f_store_test/sst_level_parse"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建不同层级的 SSTable 文件
        let buildSST = { path: String, key: UInt8 =>
            let s = SSTable(path, 1)
            s.write(ByteArray([key]), EntryValue([key + 0x10], Int64(key)))
            s.finishWrite()
            s.close()
        }
        buildSST("${dir}/L0_10.sst", 0x01)
        buildSST("${dir}/L1_20.sst", 0x10)
        buildSST("${dir}/L3_30.sst", 0x20)
        // 旧格式（无 L 前缀的兼容文件）
        buildSST("${dir}/compact_40.sst", 0x30)

        // 重新打开并检查 metadata level
        let sst0 = SSTable.open("${dir}/L0_10.sst")
        @Expect(sst0.getMetadata().level == 0)

        let sst1 = SSTable.open("${dir}/L1_20.sst")
        @Expect(sst1.getMetadata().level == 1)

        let sst3 = SSTable.open("${dir}/L3_30.sst")
        @Expect(sst3.getMetadata().level == 3)

        // 旧格式文件名无 L 前缀，应兼容降级到 level=0
        let old = SSTable.open("${dir}/compact_40.sst")
        @Expect(old.getMetadata().level == 0)

        sst0.close()
        sst1.close()
        sst3.close()
        old.close()
        remove(dir, recursive: true)
    }

    /** 验证 parseLevelFromSSTablePath 和 parseSSTIndexFromPath 辅助函数正确性 */
    @TestCase
    public func sstableParseHelpersWorkCorrectly(): Unit {
        // 正常路径
        @Expect(parseLevelFromSSTablePath("/tmp/L0_42.sst") == 0)
        @Expect(parseLevelFromSSTablePath("/tmp/L1_100.sst") == 1)
        @Expect(parseLevelFromSSTablePath("/tmp/L7_999.sst") == 7)
        @Expect(parseSSTIndexFromPath("/tmp/L0_42.sst") == 42)
        @Expect(parseSSTIndexFromPath("/tmp/L1_100.sst") == 100)
        @Expect(parseSSTIndexFromPath("/tmp/L7_999.sst") == 999)

        // 旧格式（无 L 前缀）降级
        @Expect(parseLevelFromSSTablePath("/tmp/compact_40.sst") == 0)
        @Expect(parseSSTIndexFromPath("/tmp/compact_40.sst") == 0)
    }

    /** 验证 scanBuffer 帧校验检测损坏数据（P2-1 修复验证）。
     *  创建 SSTable 后手动篡改文件内容，重开后 get() 应返回 None
     *  而非扫描损坏数据返回错误结果。 */
    @TestCase
    public func sstableScanBufferDetectsCorruptedData(): Unit {
        let dir = "/tmp/f_store_test/sst_corrupt"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建 SSTable
        let path = "${dir}/L0_1.sst"
        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.write(ByteArray([0x02]), EntryValue([0xB2], 2))
        sst.write(ByteArray([0x03]), EntryValue([0xC3], 3))
        sst.finishWrite()
        @Expect(sst.get(ByteArray([0x01])).isSome())
        @Expect(sst.get(ByteArray([0x02])).isSome())
        @Expect(sst.get(ByteArray([0x03])).isSome())
        sst.close()

        // 在数据区域写入损坏数据（将第 5 个字节改为负值 → 帧校验应检测到）
        let file = File(path, OpenMode.ReadWrite)
        file.seek(SeekPosition.Begin(4))
        file.write([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])  // 覆盖 key_len = -1
        file.close()

        // 重开 SSTable，损坏的数据块应被帧校验跳过
        let reopened = SSTable.open(path)
        @Expect(reopened.get(ByteArray([0x01])).isNone())

        reopened.close()
        remove(dir, recursive: true)
    }

    /** 验证 scanBuffer 帧校验跳过 value_len < -1 的损坏记录 */
    @TestCase
    public func sstableScanBufferRejectsInvalidValueLen(): Unit {
        let dir = "/tmp/f_store_test/sst_invalid_vlen"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1.sst"
        let sst = SSTable(path, 5)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.finishWrite()
        sst.close()

        // 在数据块中设置 value_len = -2（非法值）
        let file = File(path, OpenMode.ReadWrite)
        file.seek(SeekPosition.Begin(8))  // key_len 之后即 value_len
        file.write([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])  // value_len = -1 (tombstone 是合法的)
        // 改为更负的值 -2：writeInt64LE 写入 -2
        file.seek(SeekPosition.Begin(8))
        file.write([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        file.close()

        let reopened = SSTable.open(path)
        @Expect(reopened.get(ByteArray([0x01])).isNone())

        reopened.close()
        remove(dir, recursive: true)
    }

    /** 验证 SSTableIterator 在数据损坏时自动停止迭代（P2-4 修复验证）。
     *  loadBlock() 检测到 pread 失败后调用 setDone()，后续 next() 返回 None。 */
    @TestCase
    public func sstableIteratorStopsOnCorruptedBlock(): Unit {
        let dir = "/tmp/f_store_test/sst_iter_corrupt"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1.sst"
        let sst = SSTable(path, 10)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.write(ByteArray([0x02]), EntryValue([0xB2], 2))
        sst.finishWrite()
        sst.close()

        // 篡改数据块（写入损坏数据）
        let file = File(path, OpenMode.ReadWrite)
        file.seek(SeekPosition.Begin(0))
        file.write([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        file.close()

        // 重新打开并迭代，应因帧校验检测到损坏而停止
        let reopened = SSTable.open(path)
        let iter = reopened.iterator()
        let entries = ArrayList<(ByteArray, EntryValue)>()
        while (let Some(entry) <- iter.next()) {
            entries.add(entry)
        }
        @Expect(entries.size == 0)  // 损坏数据被跳过
        @Expect(iter.isClosed())     // 迭代器自动关闭

        reopened.close()
        remove(dir, recursive: true)
    }

    /** 验证 SSTableIterator 帧校验拒绝 valueLen < -1 的损坏记录 */
    @TestCase
    public func sstableIteratorRejectsInvalidValueLen(): Unit {
        let dir = "/tmp/f_store_test/sst_iter_vlen"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let path = "${dir}/L0_1.sst"
        let sst = SSTable(path, 5)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.finishWrite()
        sst.close()

        // 篡改 value_len 为 -2
        let file = File(path, OpenMode.ReadWrite)
        file.seek(SeekPosition.Begin(8))
        file.write([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        file.close()

        let reopened = SSTable.open(path)
        let iter = reopened.iterator()
        @Expect(iter.next().isNone())
        @Expect(iter.isClosed())

        reopened.close()
        remove(dir, recursive: true)
    }
}
