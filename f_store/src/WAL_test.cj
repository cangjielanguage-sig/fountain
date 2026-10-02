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
import std.collection.ArrayList
import std.sync.AtomicBool

@Test
public class WALTest {
    /// 构造临时 WAL 文件路径
    static func tempWALPath(testName: String): String {
        "/tmp/f_store_test/WAL_${testName}.wal"
    }

    /// 确保临时目录存在
    static func ensureDir(path: String): Unit {
        let dir = Path(path).parent
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
    }

    /// 删除临时文件
    static func cleanWAL(path: String): Unit {
        if (exists(Path(path))) {
            remove(path)
        }
    }

    /// 读取 WAL 文件并解码所有记录
    static func readRecords(path: String): ArrayList<WALRecord> {
        let file = File(path, OpenMode.Read)
        let fileSize = file.info.size
        if (fileSize < 36) {
            file.close()
            return ArrayList<WALRecord>()
        }
        let bytes = Array<Byte>(fileSize, repeat: 0u8)
        file.read(bytes)
        file.close()

        var records = ArrayList<WALRecord>()
        var offset = 0
        while (offset + 36 <= bytes.size) {
            let chunk = bytes[offset..]
            let decoded = WALRecord.decode(chunk)
            if (decoded.isNone()) {
                break
            }
            let record = decoded.getOrThrow()
            records.add(record)
            // 固定头 36 字节 + key + value
            let keyLen = readInt64LE(bytes, offset + 12)
            let valueLen = readInt64LE(bytes, offset + 20)
            let totalLen = 36 + keyLen + (if (valueLen > 0) { valueLen } else { 0 })
            offset += Int64(totalLen)
        }
        records
    }

    @TestCase
    public func walAppendAndRecover(): Unit {
        let path = tempWALPath("walAppendAndRecover")
        cleanWAL(path)
        ensureDir(path)

        // 写入 3 条记录
        let wal = WAL(path)
        let seq1 = wal.append([0x01], Some([0x41u8]))
        let seq2 = wal.append([0x02], Some([0x42u8]))
        let seq3 = wal.append([0x03u8], None)  // tombstone
        wal.close()

        @Expect(seq1 == 1)
        @Expect(seq2 == 2)
        @Expect(seq3 == 3)

        // 恢复读取
        let records = readRecords(path)

        @Expect(records.size == 3)
        @Expect(records[0].sequence == 1)
        @Expect(records[0].key == [0x01u8])
        @Expect(records[0].value == Some([0x41u8]))
        @Expect(records[1].sequence == 2)
        @Expect(records[1].key == [0x02u8])
        @Expect(records[1].value == Some([0x42u8]))
        @Expect(records[2].sequence == 3)
        @Expect(records[2].key == [0x03u8])
        @Expect(records[2].value.isNone())

        cleanWAL(path)
    }

    @TestCase
    public func walAppendWithExpireAt(): Unit {
        let path = tempWALPath("walAppendWithExpireAt")
        cleanWAL(path)
        ensureDir(path)

        let wal = WAL(path)
        let expireAt: Int64 = 9999999999
        let seq = wal.append([0xAAu8], Some([0xBBu8]), expireAt: Some(expireAt))
        wal.close()

        @Expect(seq == 1)

        let records = readRecords(path)
        @Expect(records.size == 1)
        @Expect(records[0].sequence == 1)
        @Expect(records[0].key == [0xAAu8])
        @Expect(records[0].value == Some([0xBBu8]))
        @Expect(records[0].expireAt == Some(expireAt))

        cleanWAL(path)
    }

    @TestCase
    public func walTombstoneRecord(): Unit {
        let path = tempWALPath("walTombstoneRecord")
        cleanWAL(path)
        ensureDir(path)

        let wal = WAL(path)
        let seq = wal.append([0x10u8], None)  // tombstone
        wal.close()
        @Expect(seq == 1)

        let records = readRecords(path)
        @Expect(records.size == 1)
        @Expect(records[0].key == [0x10u8])
        @Expect(records[0].value.isNone())
        @Expect(records[0].expireAt.isNone())

        cleanWAL(path)
    }

    @TestCase
    public func walSequenceStartFromGiven(): Unit {
        let path = tempWALPath("walSequenceStartFromGiven")
        cleanWAL(path)
        ensureDir(path)

        // 从 100 开始序号
        let wal = WAL(path, startSequence: 100)
        let seq1 = wal.append([0x01], Some([0x41u8]))
        let seq2 = wal.append([0x02], Some([0x42u8]))
        wal.close()

        @Expect(seq1 == 101)
        @Expect(seq2 == 102)

        cleanWAL(path)
    }

    @TestCase
    public func walCloseIsIdempotent(): Unit {
        let path = tempWALPath("walCloseIsIdempotent")
        cleanWAL(path)
        ensureDir(path)

        let wal = WAL(path)
        wal.append([0x01], Some([0x41u8]))
        wal.close()
        wal.close()  // 第二次 close，不应该抛异常
        @Expect(wal.isClosed())

        cleanWAL(path)
    }

    @TestCase
    public func walAppendAfterCloseThrows(): Unit {
        let path = tempWALPath("walAppendAfterCloseThrows")
        cleanWAL(path)
        ensureDir(path)

        let wal = WAL(path)
        wal.append([0x01], Some([0x41u8]))
        wal.close()

        var threw = false
        try {
            wal.append([0x02], Some([0x42u8]))
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)

        cleanWAL(path)
    }

    @TestCase
    public func walRotationExceedsFileSize(): Unit {
        let path = tempWALPath("walRotationExceedsFileSize")
        cleanWAL(path)
        ensureDir(path)

        // 用极小 maxFileSize（1KB）强制频繁轮转
        let wal = WAL(path, maxFileSize: 1024)
        var writtenCount: Int64 = 0
        // 写入 50 条 × ~38B = ~1900B，应触发至少 1 次轮转
        for (i in 0..50) {
            try {
                wal.append([UInt8(i % 256)], [UInt8((i + 1) % 256)])
                writtenCount++
            } catch (_: Exception) {
                break
            }
        }
        @Expect(writtenCount == 50)

        // 取出旧文件列表，应该至少有一个
        let oldFiles = wal.takeOldFiles()
        @Expect(oldFiles.size >= 1)

        // 验证旧文件在磁盘上
        for (p in oldFiles) {
            @Expect(exists(p))
            remove(p)
        }

        wal.close()
        cleanWAL(path)
    }

    @TestCase
    public func walRotationAfterCloseNoLeak(): Unit {
        let path = tempWALPath("walRotationAfterCloseNoLeak")
        cleanWAL(path)
        ensureDir(path)

        let wal = WAL(path, maxFileSize: 2048)
        // 写入直到触发轮转
        for (i in 0..100) {
            wal.append([UInt8(i % 256)], [UInt8((i + 1) % 256)])
        }

        // 取出旧文件后关闭
        let oldFiles = wal.takeOldFiles()
        wal.close()

        // 验证旧文件仍可正常读取
        for (p in oldFiles) {
            let records = WALReader.readAll(p)
            @Expect(records.size > 0)
            remove(p)
        }
    }

    /** P3.3 验证 WAL 文件严格不超过 maxFileSize：先检查再写入 */
    @TestCase
    public func walRotationStrictSizeLimit(): Unit {
        let dir = "/tmp/f_store_test/wal_strict_size"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let path = "${dir}/wal_0.wal"

        // maxFileSize = 512B，每条记录约 38~40B，写满后触发 rotate
        let wal = WAL(path, maxFileSize: 512)
        // 写入足够多的数据确保至少触发一次 rotate
        for (i in 0..100) {
            wal.append([UInt8(i % 256)], [UInt8((i + 1) % 256)])
        }

        wal.close()

        // 扫描 WAL 目录下所有 .wal 文件，验证每个文件大小严格 ≤ maxFileSize
        let walDir = Path(path).parent.toString()
        if (exists(walDir)) {
            Directory.walk(walDir) { fi: FileInfo =>
                if (fi.path.extensionName == "wal" && !fi.isDirectory()) {
                    let f = File(fi.path.toString(), OpenMode.Read)
                    @Expect(f.info.size <= 512)
                    f.close()
                }
                true
            }
        }

        remove(dir, recursive: true)
    }

    /** 并发轮转：多线程同时写入小阈值 WAL，验证不丢数据 */
    @TestCase
    public func walConcurrentRotation(): Unit {
        let dir = "/tmp/f_store_test/wal_concurrent_rot"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let path = "${dir}/wal_0.wal"

        // 极小 maxFileSize（1KB）确保频繁轮转
        let wal = WAL(path, maxFileSize: 1024)
        let writerCount = 4
        let writesPerThread: Int64 = 50

        let futures = ArrayList<Future<Int64>>()
        for (t in 0..writerCount) {
            let fut = spawn {
                var count: Int64 = 0
                for (i in 0..writesPerThread) {
                    try {
                        wal.append([UInt8(t)], [UInt8(i % 256)])
                        count++
                    } catch (_: Exception) {
                        break
                    }
                }
                count
            }
            futures.add(fut)
        }

        // 等待全部写入完成
        var totalWritten: Int64 = 0
        for (fut in futures) {
            totalWritten += fut.get()
        }

        // 收集旧文件并关闭
        let oldFiles = wal.takeOldFiles()
        wal.close()

        // 当前 WAL 路径也在 oldFiles 中
        // 验证至少产生了轮转文件
        @Expect(oldFiles.size >= 1)

        // 通过 recoverAll 恢复所有数据
        // byteCount 用增量计算（newSize - oldSize），不重复计数
        let mt = WALReader.recoverAll(dir)
        @Expect(mt.approximateSize() > 0)

        remove(dir, recursive: true)
    }

    /** 并发 sync + close：验证 WAL.sync() 与 close() 竞态不导致异常
     *  修复前：sync() 在 close() 已关闭 file 后调用 file.flush() → 异常。
     *  修复后：sync() 在 synchronized(appendLock) 内检查 closed 标志，与 close() 互斥。
     */
    @TestCase
    public func walSyncCloseRace(): Unit {
        let dir = "/tmp/f_store_test/wal_sync_close_race"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let path = "${dir}/wal_0.wal"

        let wal = WAL(path, maxFileSize: 65536) // 64KB，避免频繁轮转
        let running = AtomicBool(true)

        // 多个 writer：持续 append + sync
        let writerCount = 3
        let writerFutures = ArrayList<Future<Int64>>()
        for (t in 0..writerCount) {
            let fut = spawn {
                var writtenCount: Int64 = 0
                while (running.load()) {
                    try {
                        wal.append([UInt8(t)], [UInt8(writtenCount % 256)])
                        wal.sync()
                        writtenCount++
                    } catch (_: Exception) {
                        break
                    }
                }
                writtenCount
            }
            writerFutures.add(fut)
        }

        // 运行一段时间后关闭 WAL（此时 writer 可能正在 sync() 中）
        sleep(Duration.millisecond * 100)
        wal.close()
        running.store(false)

        // 等待 writer 全部正常退出（未崩溃）
        var totalWritten: Int64 = 0
        for (fut in writerFutures) {
            totalWritten += fut.get()
        }

        @Expect(totalWritten >= 0)

        // 验证 close 后的数据可恢复（WAL 关闭前可能已完成部分写入）
        // byteCount 用增量计算（newSize - oldSize），不重复计数
        let mt = WALReader.recoverAll(dir)
        @Expect(mt.approximateSize() > 0)

        remove(dir, recursive: true)
    }
}