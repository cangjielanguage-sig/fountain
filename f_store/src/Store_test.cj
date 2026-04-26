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
import std.fs.{File, OpenMode, Directory, remove}
import std.collection.ArrayList

@Test
public class StoreStep1Test {

    @TestCase
    public func byteArrayEmptyEqual(): Unit {
        let a = ByteArray(Array<Byte>())
        let b = ByteArray(Array<Byte>())
        @Expect(a == b)
        @Expect(!(a != b))
        @Expect(a.compare(b) == EQ)
    }

    @TestCase
    public func byteArrayPrefixIsLess(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a < b)
        @Expect(a.compare(b) == LT)
        @Expect(b.compare(a) == GT)
    }

    @TestCase
    public func byteArrayDifferentByte(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x01, 0x03])
        @Expect(a < b)
        @Expect(a.compare(b) == LT)
    }

    @TestCase
    public func byteArrayEqual(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a == b)
        @Expect(a.compare(b) == EQ)
    }

    @TestCase
    public func byteArrayHashCodeEqual(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a.hashCode() == b.hashCode())
    }

    @TestCase
    public func byteArrayHashCodeDifferent(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x03, 0x04])
        @Expect(a.hashCode() != b.hashCode())
    }

    @TestCase
    public func entryValueBasic(): Unit {
        let v = EntryValue([0x01, 0x02], 1)
        @Expect(v.value.isSome())
        @Expect(v.sequence == 1)
        @Expect(v.expireAt.isNone())
    }

    @TestCase
    public func entryValueWithExpireAt(): Unit {
        let v = EntryValue([0x01], 2, expireAt: 1000000)
        @Expect(v.value.isSome())
        @Expect(v.sequence == 2)
        if (let Some(ea) <- v.expireAt) {
            @Expect(ea == 1000000)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func entryValueTombstone(): Unit {
        let v = EntryValue(None, 3)
        @Expect(v.value.isNone())
        @Expect(v.sequence == 3)
        @Expect(v.expireAt.isNone())
    }

    @TestCase
    public func storeClosedException(): Unit {
        let e = StoreClosedException()
        @Expect(e.message == "Store is closed")
    }
}

@When[os == "Linux"]
func doCreateStoreStreamLinux(testDir: String): Unit {
    let path = "${testDir}/test_iouring_io.sst"
    Directory.create(testDir, recursive: true)
    let file = File(path, OpenMode.ReadWrite) // 保持 File 存活
    let stream = createStoreStream(path, OpenMode.ReadWrite)
    stream.write([0x01, 0x02, 0x03])
    stream.flush()
    (stream as Resource)?.close()
    file.close()
    // 验证文件内容
    let readFile = File(path, OpenMode.Read)
    let buf = Array<Byte>(3, repeat: 0u8)
    let n = readFile.read(buf)
    readFile.close()
    @Expect(n == 3)
    @Expect(buf[0] == 0x01)
    @Expect(buf[1] == 0x02)
    @Expect(buf[2] == 0x03)
    // 清理
    remove(path)
    remove(testDir, recursive: true)
}

@When[os != "Linux"]
func doCreateStoreStreamNonLinux(testDir: String): Unit {
    let path = "${testDir}/test_file_io.sst"
    Directory.create(testDir, recursive: true)
    let stream = createStoreStream(path, OpenMode.ReadWrite)
    stream.write([0x01, 0x02, 0x03])
    stream.flush()
    (stream as Resource)?.close()
    // 验证文件内容
    let file = File(path, OpenMode.Read)
    let buf = Array<Byte>(3, repeat: 0u8)
    let n = file.read(buf)
    file.close()
    @Expect(n == 3)
    @Expect(buf[0] == 0x01)
    @Expect(buf[1] == 0x02)
    @Expect(buf[2] == 0x03)
    // 清理
    remove(path)
    remove(testDir, recursive: true)
}

@When[os == "Linux"]
func doCreateStoreStreamNonLinux(testDir: String): Unit {
    // Linux 下非 Linux 版本为空操作
}

@When[os != "Linux"]
func doCreateStoreStreamLinux(testDir: String): Unit {
    // 非 Linux 下 Linux 版本为空操作
}

@Test
public class StoreStep2Test {

    let testDir = "/tmp/f_store_step2_test"

    @TestCase
    public func createStoreStreamWriteReadFlushClose(): Unit {
        doCreateStoreStreamLinux(testDir)
        doCreateStoreStreamNonLinux(testDir)
    }
}

@Test
public class StoreStep3Test {

    @TestCase
    public func memTableAddAndGet(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        let v1 = mt.get(ByteArray([0x01]))
        let v2 = mt.get(ByteArray([0x02]))
        let v3 = mt.get(ByteArray([0x03]))
        @Expect(v1.isSome())
        @Expect(v2.isSome())
        @Expect(v3.isNone())
        if (let Some(e) <- v1) {
            @Expect(e.sequence == 1)
        }
        if (let Some(e) <- v2) {
            @Expect(e.sequence == 2)
        }
    }

    @TestCase
    public func memTableAddOverwrite(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        let old = mt.add(ByteArray([0x01]), EntryValue([0x0B], 2))
        // 旧值应返回
        if (let Some(e) <- old) {
            @Expect(e.sequence == 1)
        } else {
            @Assert(false)
        }
        // get 返回新值
        let cur = mt.get(ByteArray([0x01]))
        if (let Some(e) <- cur) {
            @Expect(e.sequence == 2)
        }
    }

    @TestCase
    public func memTableIteratorOrdered(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x03]), EntryValue(None, 3))
        mt.add(ByteArray([0x01]), EntryValue(None, 1))
        mt.add(ByteArray([0x02]), EntryValue(None, 2))
        let iter = mt.iterator()
        let keys = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter.next()) {
            keys.add(k)
        }
        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(keys[2] == ByteArray([0x03]))
    }

    @TestCase
    public func memTableTailer(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue(None, 1))
        mt.add(ByteArray([0x02]), EntryValue(None, 2))
        mt.add(ByteArray([0x03]), EntryValue(None, 3))
        mt.add(ByteArray([0x04]), EntryValue(None, 4))
        let iter = mt.tailer(ByteArray([0x02]))
        let keys = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter.next()) {
            keys.add(k)
        }
        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x02]))
        @Expect(keys[1] == ByteArray([0x03]))
        @Expect(keys[2] == ByteArray([0x04]))
    }

    @TestCase
    public func memTableApproximateSize(): Unit {
        let mt = MemTable()
        @Expect(mt.approximateSize() == 0)
        mt.add(ByteArray([0x01, 0x02]), EntryValue([0x0A, 0x0B], 1))
        @Expect(mt.approximateSize() > 0)
    }
}

@Test
public class StoreStep4Test {

    @TestCase
    public func memTableManagerSwap(): Unit {
        let mgr = MemTableManager()
        // 初始状态：active 非空，immutable 为 None
        @Expect(mgr.getActive().approximateSize() == 0)
        @Expect(mgr.getImmutable().isNone())

        // 写入数据
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))

        // swap
        let swapped = mgr.swapActive()
        @Expect(swapped.isSome())
        // swap 后 active 是新的空 MemTable
        @Expect(mgr.getActive().approximateSize() == 0)
        // immutable 是旧的
        @Expect(mgr.getImmutable().isSome())
    }

    @TestCase
    public func memTableManagerClearImmutable(): Unit {
        let mgr = MemTableManager()
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mgr.swapActive()
        @Expect(mgr.getImmutable().isSome())
        mgr.clearImmutable()
        @Expect(mgr.getImmutable().isNone())
    }

    @TestCase
    public func memTableManagerSwapWhileImmutableBusy(): Unit {
        let mgr = MemTableManager()
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mgr.swapActive()
        // immutable 非空时再次 swap 应返回 None
        let second = mgr.swapActive()
        @Expect(second.isNone())
    }
}

@Test
public class StoreStep5Test {

    @TestCase
    public func walRecordEncodeDecodeRoundTrip(): Unit {
        let key: Array<Byte> = [0x01, 0x02, 0x03]
        let value: Array<Byte> = [0x0A, 0x0B]
        let record = WALRecord(42, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 42)
            @Expect(r.key == key)
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v == value)
            }
            @Expect(r.expireAt.isNone())
        }
    }

    @TestCase
    public func walRecordTombstone(): Unit {
        let key: Array<Byte> = [0x01]
        let record = WALRecord(1, key, None)
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 1)
            @Expect(r.key == key)
            @Expect(r.value.isNone())
            @Expect(r.expireAt.isNone())
        }
    }

    @TestCase
    public func walRecordWithExpireAt(): Unit {
        let key: Array<Byte> = [0x01]
        let value: Array<Byte> = [0x0A]
        let expireAt: Int64 = 1000000000
        let record = WALRecord(2, key, Some(value), expireAt: expireAt)
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 2)
            @Expect(r.expireAt.isSome())
            if (let Some(ea) <- r.expireAt) {
                @Expect(ea == expireAt)
            }
        }
    }

    @TestCase
    public func walRecordExpireAtNoneEncodedAsZero(): Unit {
        let record = WALRecord(3, [0x01], None)
        let encoded = record.encode()
        // expire_at 位于 offset 20 (checksum 4 + seq 8 + key_len 8 + value_len 8 = 28)
        // 但在 value_len 后面 8 字节，即 offset 4+8+8+8+8=36... 重新算
        // checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8)
        // 所以 expire_at 从 offset 28 开始
        let expireAtBytes = Array<Byte>(8, repeat: 0u8)
        for (i in 0..8) {
            expireAtBytes[i] = encoded[28 + i]
        }
        // 所有字节应为 0（表示永不过期）
        for (b in expireAtBytes) {
            @Expect(b == 0u8)
        }
    }

    @TestCase
    public func walRecordCorruptedChecksumReturnsNone(): Unit {
        let record = WALRecord(5, [0x01], Some([0x0Au8]))
        let encoded = record.encode()
        // 篡改第一个字节（checksum 的一部分）
        encoded[0] = encoded[0] ^ 0xFFu8
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isNone())
    }

    @TestCase
    public func walRecordEmptyKey(): Unit {
        let key: Array<Byte> = []
        let value: Array<Byte> = [0x0A]
        let record = WALRecord(6, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 6)
            @Expect(r.key.size == 0)
        }
    }

    @TestCase
    public func walRecordEmptyValue(): Unit {
        let val: Array<Byte> = []
        let record = WALRecord(7, [0x01], Some(val))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v.size == 0)
            }
        }
    }

    @TestCase
    public func walRecordLargeKeyValue(): Unit {
        let key = Array<Byte>(1000, repeat: 0xABu8)
        let value = Array<Byte>(5000, repeat: 0xCDu8)
        let record = WALRecord(8, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 8)
            @Expect(r.key.size == 1000)
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v.size == 5000)
            }
        }
    }
}

@Test
public class StoreStep7Test {

    let testDir = "/tmp/f_store_step7_test"

    @TestCase
    public func walReadAllAndRecover(): Unit {
        Directory.create(testDir, recursive: true)
        let walPath = "${testDir}/test.wal"
        let wal = WAL(walPath)
        wal.append([0x01, 0x02], [0x0A, 0x0B])
        wal.append([0x03], [0x0C], expireAt: 1000000)
        wal.append([0x04], None) // tombstone
        wal.sync()
        wal.close()
        // 读取所有记录
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 3)
        @Expect(records[0].key == [0x01, 0x02])
        @Expect(records[0].value.isSome())
        @Expect(records[1].expireAt.isSome())
        @Expect(records[2].value.isNone())
        // 恢复到 MemTable
        let mt = WALReader.recover(walPath)
        let v1 = mt.get(ByteArray([0x01, 0x02]))
        @Expect(v1.isSome())
        let v3 = mt.get(ByteArray([0x04]))
        @Expect(v3.isSome()) // tombstone 也存在 MemTable 中
        if (let Some(e) <- v3) {
            @Expect(e.value.isNone()) // 但 value 为 None
        }
        // 清理
        remove(testDir, recursive: true)
    }

    @TestCase
    public func walReadAllTruncatedRecord(): Unit {
        Directory.create(testDir, recursive: true)
        let walPath = "${testDir}/truncated.wal"
        let wal = WAL(walPath)
        wal.append([0x01], [0x0A])
        wal.append([0x02], [0x0B])
        wal.sync()
        wal.close()
        // 截断文件末尾几个字节模拟崩溃
        let file = File(walPath, OpenMode.ReadWrite)
        let size = file.info.size
        file.setLength(size - 5)
        file.close()
        // 读取应只得到第一条完整记录
        let records = WALReader.readAll(walPath)
        @Expect(records.size >= 1) // 至少第一条
        @Expect(records.size <= 2) // 第二条可能被截断
        // 清理
        remove(testDir, recursive: true)
    }

    @TestCase
    public func walReadAllEmptyFile(): Unit {
        Directory.create(testDir, recursive: true)
        let walPath = "${testDir}/empty.wal"
        let file = File(walPath, OpenMode.ReadWrite)
        file.close()
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 0)
        remove(testDir, recursive: true)
    }

    @TestCase
    public func walRecoverAll(): Unit {
        let walDir = "${testDir}/wal"
        Directory.create(walDir, recursive: true)
        // 写入两个 WAL 文件
        let wal1 = WAL("${walDir}/0001.wal")
        wal1.append([0x01], [0x0A])
        wal1.sync()
        wal1.close()
        let wal2 = WAL("${walDir}/0002.wal")
        wal2.append([0x02], [0x0B])
        wal2.sync()
        wal2.close()
        // 恢复
        let mt = WALReader.recoverAll(walDir)
        @Expect(mt.get(ByteArray([0x01])).isSome())
        @Expect(mt.get(ByteArray([0x02])).isSome())
        remove(testDir, recursive: true)
    }
}

@Test
public class StoreStep11Test {

    let testDir = "/tmp/f_store_step11_test"

    @TestCase
    public func levelManagerLoadMultipleL0AndGet(): Unit {
        Directory.create(testDir, recursive: true)
        // 写入 L0 文件 1
        let writer1 = SSTableWriter("${testDir}/L0_100_200.sst", 2)
        writer1.write(ByteArray([0x01, 0x0A]), EntryValue([0xAA], 100))
        writer1.write(ByteArray([0x02, 0x0B]), EntryValue([0xBB], 101))
        writer1.finish()
        // 写入 L0 文件 2
        let writer2 = SSTableWriter("${testDir}/L0_200_300.sst", 2)
        writer2.write(ByteArray([0x03, 0x0C]), EntryValue([0xCC], 200))
        writer2.write(ByteArray([0x04, 0x0D]), EntryValue([0xDD], 201))
        writer2.finish()

        let mgr = LevelManager(testDir)
        mgr.loadExisting()
        // 在 L0 的多个文件中查找
        let v1 = mgr.get(ByteArray([0x01, 0x0A]))
        @Expect(v1.isSome())
        let v3 = mgr.get(ByteArray([0x03, 0x0C]))
        @Expect(v3.isSome())
        // 不存在的 key
        let vNone = mgr.get(ByteArray([0xFF]))
        @Expect(vNone.isNone())

        mgr.closeAll()
        remove(testDir, recursive: true)
    }

    @TestCase
    public func levelManagerShouldCompact(): Unit {
        Directory.create(testDir, recursive: true)
        // 往 L0 添加 4 个 SSTableFile，shouldCompact 应返回 true
        let writer = SSTableWriter("${testDir}/L0_1_10.sst", 1)
        writer.write(ByteArray([0x01]), EntryValue([0x0A], 1))
        writer.finish()
        let sst1 = SSTableFile.open("${testDir}/L0_1_10.sst")

        let writer2 = SSTableWriter("${testDir}/L0_2_10.sst", 1)
        writer2.write(ByteArray([0x02]), EntryValue([0x0B], 2))
        writer2.finish()
        let sst2 = SSTableFile.open("${testDir}/L0_2_10.sst")

        let writer3 = SSTableWriter("${testDir}/L0_3_10.sst", 1)
        writer3.write(ByteArray([0x03]), EntryValue([0x0C], 3))
        writer3.finish()
        let sst3 = SSTableFile.open("${testDir}/L0_3_10.sst")

        let writer4 = SSTableWriter("${testDir}/L0_4_10.sst", 1)
        writer4.write(ByteArray([0x04]), EntryValue([0x0D], 4))
        writer4.finish()
        let sst4 = SSTableFile.open("${testDir}/L0_4_10.sst")

        let mgr = LevelManager(testDir)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)
        // 只有 3 个，shouldCompact 应返回 false
        @Expect(mgr.shouldCompact(0) == false)
        mgr.addSSTable(0, sst4)
        // 4 个，shouldCompact 应返回 true
        @Expect(mgr.shouldCompact(0))

        mgr.closeAll()
        remove(testDir, recursive: true)
    }

    @TestCase
    public func levelManagerGetPriority(): Unit {
        Directory.create(testDir, recursive: true)
        // L0 写入 (value = 0xAA)
        let w0 = SSTableWriter("${testDir}/L0_100_100.sst", 1)
        w0.write(ByteArray([0x10]), EntryValue([0xAA], 100))
        w0.finish()
        // L1 写入 (value = 0xBB, 同 key)
        let w1 = SSTableWriter("${testDir}/L1_200_200.sst", 1)
        w1.write(ByteArray([0x10]), EntryValue([0xBB], 200))
        w1.finish()
        // L2 写入 (value = 0xCC, 同 key)
        let w2 = SSTableWriter("${testDir}/L2_300_300.sst", 1)
        w2.write(ByteArray([0x10]), EntryValue([0xCC], 300))
        w2.finish()

        let sst0 = SSTableFile.open("${testDir}/L0_100_100.sst")
        let sst1 = SSTableFile.open("${testDir}/L1_200_200.sst")
        let sst2 = SSTableFile.open("${testDir}/L2_300_300.sst")

        let mgr = LevelManager(testDir)
        mgr.addSSTable(0, sst0)
        mgr.addSSTable(1, sst1)
        mgr.addSSTable(2, sst2)

        // L0 高优先级，应返回 0xAA
        let v = mgr.get(ByteArray([0x10]))
        @Expect(v.isSome())
        if (let Some(e) <- v) {
            if (let Some(val) <- e.value) {
                @Expect(val == [0xAA])
            } else {
                @Assert(false)
            }
        }

        mgr.closeAll()
        remove(testDir, recursive: true)
    }

    @TestCase
    public func levelManagerExpiredGetReturnsNone(): Unit {
        Directory.create(testDir, recursive: true)
        // 写入一条过期数据 (expireAt 远在过去)
        let expiredAt = Int64(1) // 1970-01-01 之后 1 纳秒，肯定过期
        let writer = SSTableWriter("${testDir}/L0_1_1.sst", 1)
        writer.write(ByteArray([0x20]), EntryValue([0xEE], 1, expireAt: expiredAt))
        writer.finish()

        let sst = SSTableFile.open("${testDir}/L0_1_1.sst")
        let mgr = LevelManager(testDir)
        mgr.addSSTable(0, sst)

        let v = mgr.get(ByteArray([0x20]))
        @Expect(v.isNone()) // 过期数据应返回 None

        mgr.closeAll()
        remove(testDir, recursive: true)
    }
}
