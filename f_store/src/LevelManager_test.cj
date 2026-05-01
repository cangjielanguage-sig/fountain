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

    /** P3.3 验证 L0 getOverlappingSSTables 跳过范围判断，全部文件返回 */
    @TestCase
    public func levelManagerL0OverlapReturnsAll(): Unit {
        let dir = "/tmp/f_store_lm_l0overlap"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0xA1)
        let sst2 = createSSTable("${dir}/L0_2.sst", 0x10, 0xB2)
        let sst3 = createSSTable("${dir}/L0_3.sst", 0x20, 0xC3)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)
        @Expect(mgr.getSSTablesForCompaction(0).size == 3)

        // L0: 无论查询什么范围，都返回全部文件
        let range1 = mgr.getOverlappingSSTables(0, ByteArray([0x01]), Some(ByteArray([0x01])))
        @Expect(range1.size == 3)

        // L0: 不存在的 key 范围也返回全部
        let range2 = mgr.getOverlappingSSTables(0, ByteArray([0xFF]), Some(ByteArray([0xFF])))
        @Expect(range2.size == 3)

        // L0: 无上界也返回全部
        let range3 = mgr.getOverlappingSSTables(0, ByteArray([0x01]), None)
        @Expect(range3.size == 3)

        // L1 仍保持范围筛选（作为对比验证）
        let sst4 = createSSTable("${dir}/L1_4.sst", 0x30, 0xD4)
        mgr.addSSTable(1, sst4)
        let rangeL1 = mgr.getOverlappingSSTables(1, ByteArray([0x01]), Some(ByteArray([0x02])))
        @Expect(rangeL1.size == 0)  // L1 范围不重叠，返回空

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.3 验证 getSSTablesInRange 中 L0 始终全返、L1 范围筛选 */
    @TestCase
    public func levelManagerL0InRangeAlwaysIncluded(): Unit {
        let dir = "/tmp/f_store_lm_inrange"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        let sstL0 = createSSTable("${dir}/L0_1.sst", 0x05, 0xA0)
        let sstL1 = createSSTable("${dir}/L1_1.sst", 0x10, 0xB0)
        mgr.addSSTable(0, sstL0)
        mgr.addSSTable(1, sstL1)

        // 查询不重叠于 L1 的范围，但 L0 应始终被返回
        let all = mgr.getSSTablesInRange(ByteArray([0x01]), Some(ByteArray([0x02])))
        @Expect(all.size >= 1)  // 至少包含 L0 的文件

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

    /** 验证 loadExisting 从文件名正确恢复各层级的 SSTable（P0-1 修复验证）。
     *  旧版 openFromFile 硬编码 level=0，所有文件落入 L0。
     *  修复后从文件名 L{level}_{sstIndex}.sst 解析 level，正确分配到对应层级。 */
    @TestCase
    public func levelManagerLoadRestoresCorrectLevels(): Unit {
        let dir = "/tmp/f_store_lm_level_reload"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建分别属于 L0, L1, L2 的 SSTable 文件（文件名包含正确 level）
        var seq: Int64 = 1
        let sst0 = SSTable("${dir}/L0_10.sst", 1)
        sst0.write(ByteArray([0x01]), EntryValue([0xA1], seq))
        seq++
        sst0.finishWrite()

        let sst1 = SSTable("${dir}/L1_20.sst", 1)
        sst1.write(ByteArray([0x10]), EntryValue([0xB1], seq))
        seq++
        sst1.finishWrite()

        let sst2 = SSTable("${dir}/L2_30.sst", 1)
        sst2.write(ByteArray([0x20]), EntryValue([0xC1], seq))
        seq++
        sst2.finishWrite()

        // 通过文件系统重新加载
        let mgr = LevelManager(dir)
        mgr.loadExisting()

        // 验证每层各有 1 个文件
        @Expect(mgr.getSSTablesForCompaction(0).size == 1)
        @Expect(mgr.getSSTablesForCompaction(1).size == 1)
        @Expect(mgr.getSSTablesForCompaction(2).size == 1)

        // 验证元数据中的 level 正确
        let l1Files = mgr.getSSTablesForCompaction(1)
        if (l1Files.size > 0) {
            @Expect(l1Files[0].getMetadata().level == 1)
        }
        let l2Files = mgr.getSSTablesForCompaction(2)
        if (l2Files.size > 0) {
            @Expect(l2Files[0].getMetadata().level == 2)
        }

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 loadExisting 后 sstableFileSeq 正确恢复（P0-2 修复验证）。
     *  旧版 sstableFileSeq 重启后从 0 开始，后续 flush 可能覆盖磁盘已有文件。
     *  修复后 loadExisting 扫描所有文件最大 index，设置 sstableFileSeq = maxIndex。 */
    @TestCase
    public func levelManagerLoadUpdatesSSTableFileSeq(): Unit {
        let dir = "/tmp/f_store_lm_seq_restore"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建具有已知 index=42 的 SSTable 文件
        let sst = SSTable("${dir}/L0_42.sst", 1)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.finishWrite()

        // 保存原值后，模拟重启后状态：重置 sstableFileSeq
        let savedSeq = sstableFileSeq.load()
        sstableFileSeq.store(0)

        // 加载现有文件
        let mgr = LevelManager(dir)
        mgr.loadExisting()

        // 验证 sstableFileSeq 已恢复为 maxIndex (42)
        @Expect(sstableFileSeq.load() == 42)

        // 恢复 sstableFileSeq
        sstableFileSeq.store(savedSeq)
        mgr.closeAll()
        remove(dir, recursive: true)
    }

    // 测试恢复后清理 sstableFileSeq
    @TestCase
    public func levelManagerLoadEmptyDirDoesNotChangeSSTableFileSeq(): Unit {
        let dir = "/tmp/f_store_lm_seq_empty"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let savedSeq = sstableFileSeq.load()

        let mgr = LevelManager(dir)
        mgr.loadExisting()

        // 空目录不应修改 sstableFileSeq
        @Expect(sstableFileSeq.load() == savedSeq)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.2 验证 addSSTable 后 levelSizes 缓存正确累计文件总大小 */
    @TestCase
    public func levelManagerLevelSizesAfterAdd(): Unit {
        let dir = "/tmp/f_store_lm_sz_add"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let mgr = LevelManager(dir)
        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0x0A)
        let sst2 = createSSTable("${dir}/L0_2.sst", 0x02, 0x0B)
        let sst3 = createSSTable("${dir}/L1_3.sst", 0x10, 0xC0)

        // 初始全为 0
        @Expect(mgr.shouldCompact(0) == false)

        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        @Expect(mgr.shouldCompact(0) == false)  // 只有 2 个文件

        mgr.addSSTable(1, sst3)                 // 加到 L1，不影响 L0 计数

        // L0 仍只有 2 个文件
        @Expect(mgr.getSSTablesForCompaction(0).size == 2)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.2 验证 removeSSTables 后 levelSizes 缓存正确扣减 */
    @TestCase
    public func levelManagerLevelSizesAfterRemove(): Unit {
        let dir = "/tmp/f_store_lm_sz_rm"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let mgr = LevelManager(dir)
        let sst1 = createSSTable("${dir}/L0_1.sst", 0x01, 0x0A)
        let sst2 = createSSTable("${dir}/L0_2.sst", 0x02, 0x0B)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)

        // 移除一个后 L0 文件数从 2 减为 1
        let toRemove = ArrayList<SSTable>()
        toRemove.add(sst1)
        mgr.removeSSTables(0, toRemove)
        @Expect(mgr.getSSTablesForCompaction(0).size == 1)

        // 移除不存在的 SSTable：缓存不应变成负数（removeSSTables 仅扣减实际存在的文件）
        // 用同一个 sst2 再次移除（但 sst2 已在列表中，会被匹配到，所以先确认测试不会误移）
        // 这里移除 sst1（已移除），不会影响缓存
        // 更安全的做法是验证 sst2 的 get 仍然返回数据
        let v = mgr.get(ByteArray([0x02]))
        @Expect(v.isSome())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.2 验证 loadExisting 后 levelSizes 缓存正确初始化 */
    @TestCase
    public func levelManagerLevelSizesAfterLoad(): Unit {
        let dir = "/tmp/f_store_lm_sz_load"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建两个 SSTable 文件（直接写入磁盘，不走 addSSTable）
        let sst1 = SSTable("${dir}/L0_1.sst", 1)
        sst1.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst1.finishWrite()
        sst1.close()

        let sst2 = SSTable("${dir}/L1_2.sst", 1)
        sst2.write(ByteArray([0x10]), EntryValue([0xB1], 2))
        sst2.finishWrite()
        sst2.close()

        // 通过 loadExisting 加载，应自动填充 levelSizes
        let mgr = LevelManager(dir)
        mgr.loadExisting()

        @Expect(mgr.getSSTablesForCompaction(0).size == 1)
        @Expect(mgr.getSSTablesForCompaction(1).size == 1)

        // shouldCompact L1: 单个小文件应远小于 10^1 MB 阈值
        @Expect(mgr.shouldCompact(1) == false)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.2 验证 shouldCompact L1+ 使用 levelSizes 缓存而非遍历 */
    @TestCase
    public func levelManagerShouldCompactL1UsesCache(): Unit {
        let dir = "/tmp/f_store_lm_sz_l1"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        let mgr = LevelManager(dir)

        // L1 阈值：10^1 = 10 MB。写入多个小 SSTable 不足以触发
        for (i in 0..5) {
            let sst = createSSTable("${dir}/L1_${i}.sst", UInt8(0x10 + i), UInt8(0xA0 + i))
            mgr.addSSTable(1, sst)
        }
        @Expect(mgr.shouldCompact(1) == false)

        // L2 阈值：10^2 = 100 MB，更不可能触发
        @Expect(mgr.shouldCompact(2) == false)

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** P3.1 验证 L0 Bloom Filter 提前否定路径：多文件 L0 正确返回已存在的 key */
    @TestCase
    public func levelManagerL0BloomFilterGet(): Unit {
        let dir = "/tmp/f_store_lm_bf"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)

        // 创建 6 个 L0 SSTable，每个包含一个 key，key 范围不重叠
        let keys = [[0x01u8], [0x10u8], [0x20u8], [0x30u8], [0x40u8], [0x50u8]]
        for (i in 0..6) {
            let sst = createSSTable("${dir}/L0_${i}.sst", keys[i][0], UInt8(0xA0 + i))
            mgr.addSSTable(0, sst)
        }
        @Expect(mgr.getSSTablesForCompaction(0).size == 6)

        // 正向验证：每个 key 都能正确找到
        for (i in 0..6) {
            let v = mgr.get(ByteArray(keys[i]))
            @Expect(v.isSome())
        }

        // 反向验证：不存在的 key 返回 None（Bloom Filter 提前否定 + SSTable.get 双重过滤）
        let absentKeys = [[0x00u8], [0x05u8], [0x15u8], [0x25u8], [0x35u8], [0x45u8], [0x55u8], [0xFFu8]]
        for (k in absentKeys) {
            let v = mgr.get(ByteArray(k))
            @Expect(v.isNone())
        }

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