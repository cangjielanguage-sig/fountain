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
        Directory.create(testDir, recursive: true)
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
        Directory.create(testDir, recursive: true)
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
}