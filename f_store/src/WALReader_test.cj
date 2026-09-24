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

@Test
public class WALWALReaderTest {

    let testDir = "/tmp/f_store_step7_test"

    private func setupDir(): Unit {
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir, recursive: true)
    }

    @TestCase
    public func walReadAllAndRecover(): Unit {
        setupDir()
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
        setupDir()
        let walPath = "${testDir}/test_truncated.wal"
        // 写入一条完整记录，再写入一条不完整记录
        let wal = WAL(walPath)
        wal.append([0x01], [0x0A])
        wal.sync()
        // 追加不完整数据（CRC 校验会失败）
        let file = File(walPath, OpenMode.Append)
        file.write([0xFF, 0xFF, 0xFF])
        file.close()
        wal.close()
        // 读取时应只返回一条完整记录
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 1)
        remove(testDir, recursive: true)
    }

    @TestCase
    public func walEmptyFile(): Unit {
        setupDir()
        let walPath = "${testDir}/test_empty.wal"
        // 创建空文件
        let file = File(walPath, OpenMode.ReadWrite)
        file.close()
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 0)
        remove(testDir, recursive: true)
    }

    @TestCase
    public func walRecoverMultipleFiles(): Unit {
        setupDir()
        // 写入多个 WAL 文件并恢复
        let wal1 = WAL("${testDir}/test1.wal")
        wal1.append([0x01], [0x0A])
        wal1.sync()
        wal1.close()
        let wal2 = WAL("${testDir}/test2.wal")
        wal2.append([0x02], [0x0B])
        wal2.sync()
        wal2.close()
        // 分别恢复每个 WAL
        let mt1 = WALReader.recover("${testDir}/test1.wal")
        let mt2 = WALReader.recover("${testDir}/test2.wal")
        @Expect(mt1.get(ByteArray([0x01])).isSome())
        @Expect(mt2.get(ByteArray([0x02])).isSome())
        remove(testDir, recursive: true)
    }

    /** 验证 WALReader.readAll 在遇到 checksum 损坏时截断而不是跳过
     *  3 条记录，翻转第 2 条记录 key 字节 → 第 2 条 checksum 不匹配 → 截断
     *  结果：只返回第 1 条记录
     */
    @TestCase
    public func walChecksumCorruptionSingleRecord(): Unit {
        let dir = "${testDir}/crc_single"
        Directory.create(dir, recursive: true)
        let walPath = "${dir}/test.wal"

        // 写入 3 条固定大小记录（各 1B key + 1B value，每条约 38B）
        let wal = WAL(walPath)
        wal.append([0x01], [0x0A])
        wal.append([0x02], [0x0B]) // ← 将被损坏
        wal.append([0x03], [0x0C])
        wal.sync()
        wal.close()

        // 读取文件，翻转第 2 条记录 key 字节
        let file = File(walPath, OpenMode.ReadWrite)
        let fileBytes = Array<Byte>(file.length, repeat: 0u8)
        file.read(fileBytes)
        // 第 2 条记录起始偏移: 38B，key 字节在 header(36B) 之后 → 38 + 36 = 74
        fileBytes[74] = 0xFF
        file.seek(SeekPosition.Begin(0))
        file.write(fileBytes)
        file.close()

        // 读取应只返回第 1 条（损坏处截断）
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 1)
        @Expect(records[0].sequence == 1)
        @Expect(records[0].key == [0x01])

        remove(dir, recursive: true)
    }

    /** 验证连续多条损坏仍截断在第一条损坏处
     *  5 条记录，翻转第 2、3 条 key 字节 → 第 2 条 checksum 不匹配 → 截断
     *  结果：只返回第 1 条记录
     */
    @TestCase
    public func walChecksumCorruptionConsecutive(): Unit {
        let dir = "${testDir}/crc_consec"
        Directory.create(dir, recursive: true)
        let walPath = "${dir}/test.wal"

        let wal = WAL(walPath)
        wal.append([0x01], [0x0A])
        wal.append([0x02], [0x0B]) // ← 将被损坏
        wal.append([0x03], [0x0C]) // ← 将被损坏（但截断在 2 处）
        wal.append([0x04], [0x0D])
        wal.append([0x05], [0x0E])
        wal.sync()
        wal.close()

        // 翻转第 2、3 条记录的 key 字节
        let file = File(walPath, OpenMode.ReadWrite)
        let fileBytes = Array<Byte>(file.length, repeat: 0u8)
        file.read(fileBytes)
        // 每条 38B: 第 2 条 key @ 38+36=74，第 3 条 key @ 76+36=112
        fileBytes[74] = 0xFE
        fileBytes[112] = 0xFD
        file.seek(SeekPosition.Begin(0))
        file.write(fileBytes)
        file.close()

        // 截断在第 2 条，只返回第 1 条
        let records = WALReader.readAll(walPath)
        @Expect(records.size == 1)
        @Expect(records[0].sequence == 1)

        remove(dir, recursive: true)
    }

    /** 混合恢复：空 WAL 文件 + 正常 WAL 文件 + 损坏 WAL 文件
     *  recoverAll 应正确处理全部三种情况
     */
    @TestCase
    public func walRecoverEmptyAndCorruptedMixed(): Unit {
        let dir = "${testDir}/mixed"
        Directory.create(dir, recursive: true)

        // 1. 空 WAL 文件
        let emptyPath = "${dir}/0001.wal"
        let emptyFile = File(emptyPath, OpenMode.ReadWrite)
        emptyFile.close()

        // 2. 正常 WAL 文件（3 条记录）
        let goodPath = "${dir}/0002.wal"
        let goodWal = WAL(goodPath)
        goodWal.append([0x0A], [0xAA])
        goodWal.append([0x0B], [0xBB])
        goodWal.append([0x0C], [0xCC])
        goodWal.sync()
        goodWal.close()

        // 3. 损坏 WAL 文件（第 2 条记录 key 被翻转）
        let badPath = "${dir}/0003.wal"
        let badWal = WAL(badPath)
        badWal.append([0x01], [0x11])
        badWal.append([0x02], [0x22]) // ← 将被损坏
        badWal.append([0x03], [0x33])
        badWal.sync()
        badWal.close()
        let badFile = File(badPath, OpenMode.ReadWrite)
        let badBytes = Array<Byte>(badFile.length, repeat: 0u8)
        badFile.read(badBytes)
        badBytes[38 + 36] = 0xEE  // 损坏第 2 条
        badFile.seek(SeekPosition.Begin(0))
        badFile.write(badBytes)
        badFile.close()

        // recoverAll 读取全部 3 个文件
        let mt = WALReader.recoverAll(dir)

        // 正常文件的 3 条应全在
        @Expect(mt.get(ByteArray([0x0A])).isSome())
        @Expect(mt.get(ByteArray([0x0B])).isSome())
        @Expect(mt.get(ByteArray([0x0C])).isSome())

        // 损坏文件第 1 条应在（损坏前）
        @Expect(mt.get(ByteArray([0x01])).isSome())
        // 第 2 条被截断 → 第 3 条也不在
        @Expect(mt.get(ByteArray([0x03])).isNone())

        remove(dir, recursive: true)
    }
}