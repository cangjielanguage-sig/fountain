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
public class LevelManagerTest {

    let testDir = "/tmp/f_store_step11_test"

    @TestCase
    public func levelManagerLoadMultipleL0AndGet(): Unit {
        Directory.create(testDir, recursive: true)
        // 写入 L0 文件 1
        let sst1 = SSTable("${testDir}/L0_100_200.sst", 2)
        sst1.write(ByteArray([0x01, 0x0A]), EntryValue([0xAA], 100))
        sst1.write(ByteArray([0x02, 0x0B]), EntryValue([0xBB], 101))
        sst1.finishWrite()
        // 写入 L0 文件 2
        let sst2 = SSTable("${testDir}/L0_200_300.sst", 2)
        sst2.write(ByteArray([0x03, 0x0C]), EntryValue([0xCC], 200))
        sst2.write(ByteArray([0x04, 0x0D]), EntryValue([0xDD], 201))
        sst2.finishWrite()

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
        // 往 L0 添加 4 个 SSTable，shouldCompact 应返回 true
        let sst1 = SSTable("${testDir}/L0_1_10.sst", 1)
        sst1.write(ByteArray([0x01]), EntryValue([0x0A], 1))
        sst1.finishWrite()

        let sst2 = SSTable("${testDir}/L0_2_10.sst", 1)
        sst2.write(ByteArray([0x02]), EntryValue([0x0B], 2))
        sst2.finishWrite()

        let sst3 = SSTable("${testDir}/L0_3_10.sst", 1)
        sst3.write(ByteArray([0x03]), EntryValue([0x0C], 3))
        sst3.finishWrite()

        let sst4 = SSTable("${testDir}/L0_4_10.sst", 1)
        sst4.write(ByteArray([0x04]), EntryValue([0x0D], 4))
        sst4.finishWrite()

        let mgr = LevelManager(testDir)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)
        // 只有 3 个时不应 compact
        @Expect(!mgr.shouldCompact())
        mgr.addSSTable(0, sst4)
        // 达到 4 个时应 compact
        @Expect(mgr.shouldCompact())

        mgr.closeAll()
        remove(testDir, recursive: true)
    }

    @TestCase
    public func levelManagerExpiredGet(): Unit {
        Directory.create(testDir, recursive: true)
        let sstDir = "${testDir}/expired"
        Directory.create(sstDir, recursive: true)
        // 创建一个带有过期数据的 SSTable
        let sst = SSTable("${sstDir}/L0_1_10.sst", 2)
        let expiredAt: Int64 = 1000000
        sst.write(ByteArray([0x20]), EntryValue([0xEE], 1, expireAt: expiredAt))
        sst.finishWrite()

        let mgr = LevelManager(testDir)
        mgr.addSSTable(0, sst)

        let v = mgr.get(ByteArray([0x20]))
        @Expect(v.isNone()) // 过期数据应返回 None

        mgr.closeAll()
        remove(testDir, recursive: true)
    }
}