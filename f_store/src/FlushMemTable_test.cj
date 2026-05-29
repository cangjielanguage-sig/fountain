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
public class FlushMemTableTest {

    let testDir = "/tmp/f_store_step12_test"

    @TestCase
    public func flushSmallMemTableProducesOneSSTable(): Unit {
        Directory.create(testDir, recursive: true)
        let sstDir = "${testDir}/sst"
        // 创建 MemTable 并写入少量数据
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        mt.add(ByteArray([0x03]), EntryValue([0x0C], 3))

        // 刷盘
        let ssts = flushMemTable(mt, sstDir, 0)
        @Expect(ssts.size == 1)

        // 刷盘后的 SSTable 应该能正确读取
        let sst = ssts[0]
        let v1 = sst.get(ByteArray([0x01]))
        @Expect(v1.isSome())
        if (let Some(e) <- v1) {
            if (let Some(val) <- e.value) {
                @Expect(val == [0x0A])
            }
        }
        let v2 = sst.get(ByteArray([0x02]))
        @Expect(v2.isSome())
        let vNone = sst.get(ByteArray([0xFF]))
        @Expect(vNone.isNone())

        // 清理
        for (s in ssts) {
            s.close()
        }
        remove(testDir, recursive: true)
    }

    @TestCase
    public func flushMemTableAndLevelManagerGet(): Unit {
        Directory.create(testDir, recursive: true)
        let sstDir = "${testDir}/sst"
        // 创建 MemTable 并写入
        let mt = MemTable()
        mt.add(ByteArray([0x10]), EntryValue([0xAA], 100))
        mt.add(ByteArray([0x20]), EntryValue([0xBB], 200))

        // 刷盘
        let ssts = flushMemTable(mt, sstDir, 0)
        @Expect(ssts.size == 1)

        // 刷盘后的数据应能通过 LevelManager 查询
        let mgr = LevelManager(sstDir)
        mgr.loadExisting()
        let v1 = mgr.get(ByteArray([0x10]))
        @Expect(v1.isSome())
        if (let Some(e) <- v1) {
            if (let Some(val) <- e.value) {
                @Expect(val == [0xAA])
            }
        }
        let v2 = mgr.get(ByteArray([0x20]))
        @Expect(v2.isSome())

        mgr.closeAll()
        for (s in ssts) {
            s.close()
        }
        remove(testDir, recursive: true)
    }

    @TestCase
    public func flushWithTombstoneAndExpire(): Unit {
        Directory.create(testDir, recursive: true)
        let sstDir = "${testDir}/sst"
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))           // 正常值
        mt.add(ByteArray([0x02]), EntryValue(None, 2))             // tombstone
        mt.add(ByteArray([0x03]), EntryValue([0x0C], 3, expireAt: 100))
        mt.add(ByteArray([0x04]), EntryValue([0x0D], 4))           // 正常值

        let ssts = flushMemTable(mt, sstDir, 0)

        let mgr = LevelManager(sstDir)
        mgr.loadExisting()
        @Expect(mgr.get(ByteArray([0x01])).isSome()) // 正常值
        @Expect(mgr.get(ByteArray([0x02])).isNone()) // tombstone → None
        @Expect(mgr.get(ByteArray([0x03])).isNone()) // 过期 → None
        @Expect(mgr.get(ByteArray([0x04])).isSome()) // 正常值

        mgr.closeAll()
        remove(testDir, recursive: true)
    }
}