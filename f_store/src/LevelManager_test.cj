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
        @Expect(!mgr.shouldCompact(0))
        mgr.addSSTable(0, sst4)
        // 达到 4 个时应 compact
        @Expect(mgr.shouldCompact(0))

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

    /** 验证 addSSTable 后 getSSTablesForCompaction 返回正确的快照 */
    @TestCase
    public func levelManagerGetSSTablesForCompaction(): Unit {
        let dir = "/tmp/f_store_lm_comp_snap"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        // 空层返回空
        let empty = mgr.getSSTablesForCompaction(0)
        @Expect(empty.size == 0)

        // 添加 2 个 SSTable
        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0x0A)
        let sst2 = createSSTable("${dir}/L0_2.sst", 0x02, 0x0B)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)

        let snap = mgr.getSSTablesForCompaction(0)
        @Expect(snap.size == 2)

        // 验证快照包含正确的引用（通过 get 验证数据可达）
        let v1 = mgr.get(ByteArray([0x01]))
        @Expect(v1.isSome())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 removeSSTables 正确移除指定 SSTable */
    @TestCase
    public func levelManagerRemoveSSTables(): Unit {
        let dir = "/tmp/f_store_lm_remove"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0x0A)
        let sst2 = createSSTable("${dir}/L0_2.sst", 0x02, 0x0B)
        let sst3 = createSSTable("${dir}/L0_3.sst", 0x03, 0x0C)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)
        @Expect(mgr.getSSTablesForCompaction(0).size == 3)

        // 移除中间那个
        let toRemove = ArrayList<SSTable>()
        toRemove.add(sst2)
        mgr.removeSSTables(0, toRemove)

        let remaining = mgr.getSSTablesForCompaction(0)
        @Expect(remaining.size == 2)

        // 移除不存在的 SSTable 不报错
        let fakeSst = createSSTable("${dir}/L0_fake.sst", 0xFF, 0xEE)
        let notPresent = ArrayList<SSTable>()
        notPresent.add(fakeSst)
        mgr.removeSSTables(0, notPresent)
        @Expect(mgr.getSSTablesForCompaction(0).size == 2)

        fakeSst.close()
        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 removeSSTables 对无效层不报错 */
    @TestCase
    public func levelManagerRemoveInvalidLevel(): Unit {
        let dir = "/tmp/f_store_lm_remove_inv"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)
        mgr.removeSSTables(-1, ArrayList<SSTable>())  // 负数 level
        mgr.removeSSTables(100, ArrayList<SSTable>()) // 超出范围
        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 getOverlappingSSTables 的范围匹配 */
    @TestCase
    public func levelManagerGetOverlappingSSTables(): Unit {
        let dir = "/tmp/f_store_lm_overlap"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        // 创建 3 个 key 范围不重叠的 SSTable
        let sst1 = createSSTableRange("${dir}/L1_a.sst", 0x01, 0x03, [0xA1, 0xA2, 0xA3])
        let sst2 = createSSTableRange("${dir}/L1_b.sst", 0x10, 0x12, [0xB1, 0xB2, 0xB3])
        let sst3 = createSSTableRange("${dir}/L1_c.sst", 0x20, 0x22, [0xC1, 0xC2, 0xC3])

        mgr.addSSTable(1, sst1)
        mgr.addSSTable(1, sst2)
        mgr.addSSTable(1, sst3)

        // 查询范围 [0x02, 0x11] 应匹配 sst1 和 sst2
        let range1 = mgr.getOverlappingSSTables(1, ByteArray([0x02]), Some(ByteArray([0x11])))
        @Expect(range1.size == 2)  // sst1 和 sst2

        // 查询单个 key 范围 [0x00, 0x01] 应只匹配 sst1
        let range2 = mgr.getOverlappingSSTables(1, ByteArray([0x00]), Some(ByteArray([0x01])))
        @Expect(range2.size == 1)

        // 无上界查询 [0x10, None) 应匹配 sst2 和 sst3
        let range3 = mgr.getOverlappingSSTables(1, ByteArray([0x10]), None)
        @Expect(range3.size == 2)

        // 不存在的范围 [0x30, 0x40] 应返回 0
        let range4 = mgr.getOverlappingSSTables(1, ByteArray([0x30]), Some(ByteArray([0x40])))
        @Expect(range4.size == 0)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 getSSTablesInRange 跨层返回结果 */
    @TestCase
    public func levelManagerGetSSTablesInRange(): Unit {
        let dir = "/tmp/f_store_lm_range"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        let sstL0 = createSSTableRange("${dir}/L0_a.sst", 0x01, 0x02, [0xA1, 0xA2])
        let sstL1 = createSSTableRange("${dir}/L1_a.sst", 0x03, 0x04, [0xB3, 0xB4])
        mgr.addSSTable(0, sstL0)
        mgr.addSSTable(1, sstL1)

        // getSSTablesInRange 应返回跨层结果
        let all = mgr.getSSTablesInRange(ByteArray([0x01]), Some(ByteArray([0x04])))
        @Expect(all.size >= 2)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 levelSummary 的格式 */
    @TestCase
    public func levelManagerLevelSummary(): Unit {
        let dir = "/tmp/f_store_lm_summary"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0x0A)
        mgr.addSSTable(0, sst1)

        let summary = mgr.levelSummary()
        @Expect(summary.size > 0)
        @Expect(summary.contains("L0"))

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    // ================================================================
    // 辅助方法
    // ================================================================

    private func createSSTable(path: String, key: UInt8, value: UInt8): SSTable {
        let idx = path.lastIndexOf('/').getOrThrow()
        let dir = path[0 .. idx]
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let sst = SSTable(path, 1)
        sst.write(ByteArray([key]), EntryValue([value], Int64(key)))
        sst.finishWrite()
        sst
    }

    private func createSSTableRange(path: String, start: UInt8, end: UInt8, values: Array<UInt8>): SSTable {
        let idx = path.lastIndexOf('/').getOrThrow()
        let dir = path[0 .. idx]
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let count = Int64(end) - Int64(start) + 1
        let capacity = if (count > 0) { count } else { 1 }
        let sst = SSTable(path, capacity)
        for (i in 0..count) {
            let k = start + UInt8(i)
            let v = if (i < values.size) { values[Int64(i)] } else { k }
            sst.write(ByteArray([k]), EntryValue([v], Int64(k)))
        }
        sst.finishWrite()
        sst
    }
}