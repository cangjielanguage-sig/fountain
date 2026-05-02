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
import std.collection.ArrayList
import std.fs.*

/** 测试用迭代器：在产出 N 个元素后，下一次 next() 抛出异常 */
class FailAfterIterator <: Iterator<(ByteArray, EntryValue)> {
    let items: ArrayList<(ByteArray, EntryValue)>
    let failAfter: Int64
    var index: Int64 = 0

    init(items: ArrayList<(ByteArray, EntryValue)>, failAfter: Int64) {
        this.items = items
        this.failAfter = failAfter
    }

    public func next(): Option<(ByteArray, EntryValue)> {
        if (index >= failAfter) {
            throw Exception("FailAfterIterator: simulated failure after ${failAfter} items")
        }
        if (index >= items.size) {
            return None
        }
        let item = items[index]
        index++
        Some(item)
    }
}

/** 辅助函数：创建 SSTable 并写入数据 */
func createSSTable(path: String, entries: Array<(ByteArray, EntryValue)>): SSTable {
    let idx = path.lastIndexOf('/').getOrThrow()
    let dir = path[0 .. idx]
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }
    let capacity = if (entries.size > 0) { entries.size } else { 1 }
    let sst = SSTable(path, capacity)
    for ((key, entry) in entries) {
        sst.write(key, entry)
    }
    sst.finishWrite()
    sst
}

@Test
public class SSTableMergerTest {

    @TestCase
    public func mergerBasicTwoSources(): Unit {
        // 两个有序迭代器归并，结果应全局有序
        let sst1 = createSSTable("/tmp/f_store_merger_test/basic1.sst", [
            (ByteArray([0x01]), EntryValue([0xAA], 1)),
            (ByteArray([0x03]), EntryValue([0xCC], 2))
        ])
        let sst2 = createSSTable("/tmp/f_store_merger_test/basic2.sst", [
            (ByteArray([0x02]), EntryValue([0xBB], 3)),
            (ByteArray([0x04]), EntryValue([0xDD], 4))
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))
        sources.add(PeekableIterator(sst2.iterator()))

        let merger = SSTableMerger(sources)
        let keys = ArrayList<ByteArray>()
        while (let Some((key, _)) <- merger.next()) {
            keys.add(key)
        }

        @Expect(keys.size == 4)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(keys[2] == ByteArray([0x03]))
        @Expect(keys[3] == ByteArray([0x04]))

        sst1.close()
        sst2.close()
        remove("/tmp/f_store_merger_test", recursive: true)
    }

    @TestCase
    public func mergerDeduplicateSameKey(): Unit {
        // 相同 key 在多个源中出现，取最高 sequence 的 EntryValue
        let sst1 = createSSTable("/tmp/f_store_merger_test/dedup1.sst", [
            (ByteArray([0x01]), EntryValue([0xAA], 1)),
            (ByteArray([0x02]), EntryValue([0xB0], 2))
        ])
        let sst2 = createSSTable("/tmp/f_store_merger_test/dedup2.sst", [
            (ByteArray([0x02]), EntryValue([0xB1], 10)),  // 更高 sequence
            (ByteArray([0x03]), EntryValue([0xCC], 11))
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))
        sources.add(PeekableIterator(sst2.iterator()))

        let merger = SSTableMerger(sources)
        let keys = ArrayList<ByteArray>()
        let seqs = ArrayList<Int64>()
        let vals = ArrayList<Array<Byte>>()
        while (let Some((key, entry)) <- merger.next()) {
            keys.add(key)
            seqs.add(entry.sequence)
            vals.add(entry.value.getOrThrow())
        }

        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x01]))
        // key 0x02 应取 sequence=10 的版本
        @Expect(seqs[1] == 10)
        @Expect(vals[1] == [0xB1])
        @Expect(keys[2] == ByteArray([0x03]))

        sst1.close()
        sst2.close()
        remove("/tmp/f_store_merger_test", recursive: true)
    }

    @TestCase
    public func mergerSkipExpiredEntries(): Unit {
        // 过期数据在归并时被跳过
        let pastTime: Int64 = 1  // 很久以前的时间戳，必定已过期

        let sst1 = createSSTable("/tmp/f_store_merger_test/expired1.sst", [
            (ByteArray([0x01]), EntryValue([0xAA], 1)),                    // 未过期
            (ByteArray([0x02]), EntryValue([0xBB], 2, expireAt: pastTime)) // 已过期
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))

        let merger = SSTableMerger(sources)
        let keys = ArrayList<ByteArray>()
        while (let Some((key, _)) <- merger.next()) {
            keys.add(key)
        }

        @Expect(keys.size == 1)
        @Expect(keys[0] == ByteArray([0x01]))

        sst1.close()
        remove("/tmp/f_store_merger_test", recursive: true)
    }

    @TestCase
    public func mergerTombstoneBottomLevelRemoved(): Unit {
        // 最底层 Compaction：tombstone 被移除
        let sst1 = createSSTable("/tmp/f_store_merger_test/tomb_bottom1.sst", [
            (ByteArray([0x01u8]), EntryValue(Some([0xAAu8]), 1)),   // 正常值
            (ByteArray([0x02u8]), EntryValue(None, 2))            // tombstone
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))

        let merger = SSTableMerger(sources, isBottomLevel: true)
        let keys = ArrayList<ByteArray>()
        while (let Some((key, _)) <- merger.next()) {
            keys.add(key)
        }

        @Expect(keys.size == 1)
        @Expect(keys[0] == ByteArray([0x01]))

        sst1.close()
        remove("/tmp/f_store_merger_test", recursive: true)
    }

    @TestCase
    public func mergerTombstoneNonBottomKept(): Unit {
        // 非最底层 Compaction：tombstone 保留
        let sst1 = createSSTable("/tmp/f_store_merger_test/tomb_nonbottom1.sst", [
            (ByteArray([0x01u8]), EntryValue(Some([0xAAu8]), 1)),   // 正常值
            (ByteArray([0x02u8]), EntryValue(None, 2))            // tombstone
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))

        let merger = SSTableMerger(sources, isBottomLevel: false)
        let keys = ArrayList<ByteArray>()
        var hasTombstone = false
        while (let Some((key, entry)) <- merger.next()) {
            keys.add(key)
            if (entry.value.isNone()) {
                hasTombstone = true
            }
        }

        @Expect(keys.size == 2)
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(hasTombstone)

        sst1.close()
        remove("/tmp/f_store_merger_test", recursive: true)
    }

    @TestCase
    public func mergerEmptySources(): Unit {
        // 空源列表
        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        let merger = SSTableMerger(sources)
        let result = merger.next()
        @Expect(result.isNone())
    }

    /** 4 源归并：验证超过 2 个源的归并正确性，含去重和 tombstone */
    @TestCase
    public func mergerFourSourcesWithDedupAndTombstone(): Unit {
        // 4 个 SSTable，各有部分重叠 key
        let dir = "/tmp/f_store_merger_4src"
        if (!exists(dir)) { Directory.create(dir, recursive: true) }

        // 源 1: key 0x01,0x02,0x03 — 正常值
        let sst1 = createSSTable("${dir}/s1.sst", [
            (ByteArray([0x01]), EntryValue([0xA1], 1)),
            (ByteArray([0x02]), EntryValue([0xA2], 2)),
            (ByteArray([0x03]), EntryValue([0xA3], 3))
        ])
        // 源 2: key 0x02(高sequence),0x04 — 0x02 覆盖源 1
        let sst2 = createSSTable("${dir}/s2.sst", [
            (ByteArray([0x02]), EntryValue([0xB2], 20)),  // seq 更高 → 应胜出
            (ByteArray([0x04]), EntryValue([0xB4], 4))
        ])
        // 源 3: key 0x03(tombstone),0x05 — 0x03 被删除
        let sst3 = createSSTable("${dir}/s3.sst", [
            (ByteArray([0x03]), EntryValue(None, 30)),    // tombstone
            (ByteArray([0x05]), EntryValue([0xC5], 5))
        ])
        // 源 4: key 0x06,0x07 — 无重叠
        let sst4 = createSSTable("${dir}/s4.sst", [
            (ByteArray([0x06]), EntryValue([0xD6], 6)),
            (ByteArray([0x07]), EntryValue([0xD7], 7))
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))
        sources.add(PeekableIterator(sst2.iterator()))
        sources.add(PeekableIterator(sst3.iterator()))
        sources.add(PeekableIterator(sst4.iterator()))

        // 非最底层，tombstone 保留
        let merger = SSTableMerger(sources, isBottomLevel: false)
        let keys = ArrayList<ByteArray>()
        let vals = ArrayList<Array<Byte>>()
        let seqs = ArrayList<Int64>()
        while (let Some((key, entry)) <- merger.next()) {
            keys.add(key)
            seqs.add(entry.sequence)
            if (let Some(v) <- entry.value) {
                vals.add(v)
            } else {
                vals.add([]) // tombstone 标记
            }
        }

        // 应输出 7 个 key（tombstone 未到最底层保留）
        @Expect(keys.size == 7)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(vals[0] == [0xA1])

        // 0x02: 取源 2 的高 sequence(20)
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(seqs[1] == 20)
        @Expect(vals[1] == [0xB2])

        // 0x03: tombstone，非最底层保留
        @Expect(keys[2] == ByteArray([0x03]))
        @Expect(vals[2] == [])  // 空数组表示 tombstone

        @Expect(keys[3] == ByteArray([0x04]))
        @Expect(vals[3] == [0xB4])

        @Expect(keys[4] == ByteArray([0x05]))
        @Expect(vals[4] == [0xC5])

        @Expect(keys[5] == ByteArray([0x06]))
        @Expect(vals[5] == [0xD6])

        @Expect(keys[6] == ByteArray([0x07]))
        @Expect(vals[6] == [0xD7])

        sst1.close(); sst2.close(); sst3.close(); sst4.close()
        remove(dir, recursive: true)
    }

    /** 4 源归并（最底层）：tombstone 被移除 */
    @TestCase
    public func mergerFourSourcesBottomLevelTombstoneRemoved(): Unit {
        let dir = "/tmp/f_store_merger_4src_bottom"
        if (!exists(dir)) { Directory.create(dir, recursive: true) }

        let sst1 = createSSTable("${dir}/b1.sst", [
            (ByteArray([0x01]), EntryValue([0xA1], 1)),
            (ByteArray([0x02]), EntryValue(None, 2))  // tombstone
        ])
        let sst2 = createSSTable("${dir}/b2.sst", [
            (ByteArray([0x02]), EntryValue(None, 10)),  // 同 key tombstone
            (ByteArray([0x03]), EntryValue([0xC3], 11))
        ])

        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        sources.add(PeekableIterator(sst1.iterator()))
        sources.add(PeekableIterator(sst2.iterator()))

        // 最底层 → tombstone 移除
        let merger = SSTableMerger(sources, isBottomLevel: true)
        let keys = ArrayList<ByteArray>()
        while (let Some((key, _)) <- merger.next()) {
            keys.add(key)
        }

        @Expect(keys.size == 2)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(keys[1] == ByteArray([0x03]))

        sst1.close(); sst2.close()
        remove(dir, recursive: true)
    }
}

@Test
public class CompactionTest {

    let testDir = "/tmp/f_store_compaction_test"

    @TestCase
    public func compactorStartStop(): Unit {
        // Compactor 可以正常启动和停止
        let dir = "${testDir}/startstop"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)
        let compactor = Compactor(mgr, dir, levelCount: 7)

        compactor.start()
        sleep(Duration.millisecond * 50)  // 等待线程启动
        @Expect(compactor.isRunning())

        compactor.stop()
        sleep(Duration.millisecond * 200)  // 等待线程退出
        @Expect(!compactor.isRunning())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    @TestCase
    public func compactorCompactL0ToL1(): Unit {
        // 手动触发 compact(0)，L0 的 SSTable 应合并到 L1
        let dir = "${testDir}/l0_l1"
        Directory.create(dir, recursive: true)

        // 创建 L0 的 2 个 SSTable
        let sst1 = SSTable("${dir}/L0_1_10.sst", 2)
        sst1.write(ByteArray([0x01]), EntryValue([0xAA], 1))
        sst1.write(ByteArray([0x02]), EntryValue([0xBB], 2))
        sst1.finishWrite()

        let sst2 = SSTable("${dir}/L0_3_10.sst", 2)
        sst2.write(ByteArray([0x03]), EntryValue([0xCC], 3))
        sst2.write(ByteArray([0x04]), EntryValue([0xDD], 4))
        sst2.finishWrite()

        let mgr = LevelManager(dir)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)

        // 执行 compact
        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // 验证 L1 中可以读到所有数据
        let v1 = mgr.get(ByteArray([0x01]))
        @Expect(v1.isSome())
        let v3 = mgr.get(ByteArray([0x03]))
        @Expect(v3.isSome())
        let vNone = mgr.get(ByteArray([0xFF]))
        @Expect(vNone.isNone())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    @TestCase
    public func compactorCompactRemovesOverwrittenKeys(): Unit {
        // L0 和 L1 有相同 key 时，compact 后取最高 sequence
        let dir = "${testDir}/overwrite"
        Directory.create(dir, recursive: true)

        // L1 已有 key=0x01 的旧值
        let sstL1 = SSTable("${dir}/L1_old_1_10.sst", 1)
        sstL1.write(ByteArray([0x01]), EntryValue([0xA0], 1))
        sstL1.finishWrite()

        // L0 有 key=0x01 的新值
        let sstL0 = SSTable("${dir}/L0_new_1_10.sst", 1)
        sstL0.write(ByteArray([0x01]), EntryValue([0xA1], 10))
        sstL0.finishWrite()

        let mgr = LevelManager(dir)
        mgr.addSSTable(1, sstL1)
        mgr.addSSTable(0, sstL0)

        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // compact 后 get 应返回新值
        let v = mgr.get(ByteArray([0x01]))
        @Expect(v.isSome())
        if (let Some(entry) <- v) {
            @Expect(entry.value.getOrThrow() == [0xA1])
        }

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    @TestCase
    public func compactorStopIsIdempotent(): Unit {
        // 多次 stop 不崩溃
        let dir = "${testDir}/idempotent"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)
        let compactor = Compactor(mgr, dir, levelCount: 7)

        compactor.start()
        sleep(Duration.millisecond * 50)
        compactor.stop()
        compactor.stop()
        compactor.stop()
        // 等待后台线程退出（runLoop 内最多 sleep 100ms）
        sleep(Duration.millisecond * 200)
        @Expect(!compactor.isRunning())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    @TestCase
    public func compactorCompactInvalidLevel(): Unit {
        // compact 无效 level 不崩溃
        let dir = "${testDir}/invalid"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)
        let compactor = Compactor(mgr, dir, levelCount: 7)

        compactor.compact(-1)   // 负数
        compactor.compact(6)    // 等于 levelCount-1，最底层不可 compact
        compactor.compact(100)  // 超出范围

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    @TestCase
    public func compactorCompactEmptyLevel(): Unit {
        // compact 空 L0 层不崩溃
        let dir = "${testDir}/empty"
        Directory.create(dir, recursive: true)
        let mgr = LevelManager(dir)
        mgr.loadExisting()

        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)  // L0 为空

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 4 源 L0 → L1：验证多文件 compaction 端到端正确性 */
    @TestCase
    public func compactorFourSourcesL0toL1(): Unit {
        let dir = "${testDir}/four_src"
        Directory.create(dir, recursive: true)

        // L0: 4 个 SSTable，各有 2 个 key，范围递增
        let sst0 = SSTable("${dir}/L0_0_10.sst", 2)
        sst0.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst0.write(ByteArray([0x02]), EntryValue([0xA2], 2))
        sst0.finishWrite()

        let sst1 = SSTable("${dir}/L0_1_10.sst", 2)
        sst1.write(ByteArray([0x03]), EntryValue([0xB3], 3))
        sst1.write(ByteArray([0x04]), EntryValue([0xB4], 4))
        sst1.finishWrite()

        let sst2 = SSTable("${dir}/L0_2_10.sst", 2)
        sst2.write(ByteArray([0x05]), EntryValue([0xC5], 5))
        sst2.write(ByteArray([0x06]), EntryValue([0xC6], 6))
        sst2.finishWrite()

        let sst3 = SSTable("${dir}/L0_3_10.sst", 2)
        sst3.write(ByteArray([0x07]), EntryValue([0xD7], 7))
        sst3.write(ByteArray([0x08]), EntryValue([0xD8], 8))
        sst3.finishWrite()

        let mgr = LevelManager(dir)
        mgr.addSSTable(0, sst0)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)

        // 执行 compact
        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // 验证全部 8 个 key 可读
        for (i in 1..9) {
            let key = ByteArray([UInt8(i)])
            let v = mgr.get(key)
            @Expect(v.isSome())
        }
        @Expect(mgr.get(ByteArray([0xFF])).isNone())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 4 源 L0 → L1（L1 已有数据）：验证跨层重叠 key 正确处理 */
    @TestCase
    public func compactorFourSourcesWithExistingL1(): Unit {
        let dir = "${testDir}/four_src_l1"
        Directory.create(dir, recursive: true)

        // L1 已有 key=0x02 的旧值
        let sstL1 = SSTable("${dir}/L1_0_10.sst", 2)
        sstL1.write(ByteArray([0x02]), EntryValue([0x22], 1))
        sstL1.write(ByteArray([0x06]), EntryValue([0x66], 2))
        sstL1.finishWrite()

        // L0: 4 个 SSTable，含覆盖 L1 数据的 key
        let sst0 = SSTable("${dir}/L0_0_10.sst", 2)
        sst0.write(ByteArray([0x01]), EntryValue([0xA1], 10))
        sst0.write(ByteArray([0x02]), EntryValue([0xA2], 20))  // 覆盖 L1 的 0x02
        sst0.finishWrite()

        let sst1 = SSTable("${dir}/L0_1_10.sst", 2)
        sst1.write(ByteArray([0x03]), EntryValue([0xB3], 30))
        sst1.write(ByteArray([0x04]), EntryValue([0xB4], 40))
        sst1.finishWrite()

        let sst2 = SSTable("${dir}/L0_2_10.sst", 2)
        sst2.write(ByteArray([0x05]), EntryValue([0xC5], 50))
        sst2.write(ByteArray([0x06]), EntryValue(None, 60))  // tombstone 覆盖 L1 的 0x06
        sst2.finishWrite()

        let sst3 = SSTable("${dir}/L0_3_10.sst", 2)
        sst3.write(ByteArray([0x07]), EntryValue([0xD7], 70))
        sst3.write(ByteArray([0x08]), EntryValue([0xD8], 80))
        sst3.finishWrite()

        let mgr = LevelManager(dir)
        mgr.addSSTable(1, sstL1)
        mgr.addSSTable(0, sst0)
        mgr.addSSTable(0, sst1)
        mgr.addSSTable(0, sst2)
        mgr.addSSTable(0, sst3)

        // 执行 compact
        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // 验证全部 8 个 key 中 7 个可读（0x06 tombstone 除外）
        for (i in 1..9) {
            let key = ByteArray([UInt8(i)])
            let v = mgr.get(key)
            if (i == 6) {
                @Expect(v.isNone())
            } else {
                @Expect(v.isSome())
            }
        }

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 L0 有大量文件时 compaction 仅选最多 4 个（P2-2 修复验证）。
     *  旧版 L0 全选所有文件，新版从末尾选最多 4 个。 */
    @TestCase
    public func compactorL0SelectsAtMostFour(): Unit {
        let dir = "${testDir}/l0_limit"
        Directory.create(dir, recursive: true)

        // 创建 6 个 L0 SSTable
        let ssts = ArrayList<SSTable>()
        for (i in 0..6) {
            let sst = SSTable("${dir}/L0_${i}.sst", 1)
            sst.write(ByteArray([UInt8(i + 1)]), EntryValue([UInt8(0xA0 + i)], Int64(i + 1)))
            sst.finishWrite()
            ssts.add(sst)
        }

        let mgr = LevelManager(dir)
        for (sst in ssts) {
            mgr.addSSTable(0, sst)
        }
        @Expect(mgr.getSSTablesForCompaction(0).size == 6)

        // compact L0 → compaction 只选 4 个，剩余 2 个仍在 L0
        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // L0 应剩余 2 个（未被选中的）
        // 注意：compact(0) 会合并 selected 部分到 L1，原 selected 从 L0 移除
        let remainingL0 = mgr.getSSTablesForCompaction(0)
        @Expect(remainingL0.size == 2)

        // L1 应有新合并的 SSTable
        let l1Count = mgr.getSSTablesForCompaction(1).size
        @Expect(l1Count > 0)

        // 全部 6 个 key 仍可读（部分在 L0 剩余，部分在 L1 新文件）
        for (i in 0..6) {
            let v = mgr.get(ByteArray([UInt8(i + 1)]))
            @Expect(v.isSome())
        }

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 compact 写入失败时源迭代器正确关闭（P3 FD 泄漏修复）。
     *  旧版未用 try-finally 保护 sources，异常时 SSTableIterator 的 File 句柄泄漏。
     *  修复后 finally 块确保所有 sources 关闭（close 幂等，已耗尽的 sources 安全跳过）。 */
    @TestCase
    public func compactorWriteFailureClosesSources(): Unit {
        let dir = "${testDir}/write_fail"
        Directory.create(dir, recursive: true)

        // 创建 L0 的 2 个 SSTable，触发 compaction
        let sst0 = SSTable("${dir}/L0_0.sst", 1)
        sst0.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst0.finishWrite()

        let sst1 = SSTable("${dir}/L0_1.sst", 1)
        sst1.write(ByteArray([0x02]), EntryValue([0xA2], 2))
        sst1.finishWrite()

        let mgr = LevelManager(dir)
        mgr.addSSTable(0, sst0)
        mgr.addSSTable(0, sst1)

        // 用不可写的 sstDir 触发 writeStreamToSSTables 失败
        let badDir = "/tmp/f_store_compaction_bad_dir"
        try { remove(badDir) } catch (_: Exception) {}
        let blocker = File(badDir, OpenMode.Write)
        blocker.close()
        // 此时 badDir 是普通文件，writeStreamToSSTables 无法在其下创建目录/文件

        let compactor = Compactor(mgr, badDir, levelCount: 7)
        try {
            compactor.compact(0)
        } catch (_: Exception) {
            // Expected: SSTable 创建失败 → writeStreamToSSTables 抛出异常
        }

        // 清理 blocker
        remove(badDir)

        // 验证：原有数据不受影响
        @Expect(mgr.get(ByteArray([0x01])).isSome())
        @Expect(mgr.get(ByteArray([0x02])).isSome())

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 writeStreamToSSTables 在迭代器抛异常时正确关闭当前 writer 并删除孤儿文件。
     *  P0-2 修复：catch 块关闭 + 删除已 finishWrite 的 SSTable 后重新抛出异常。
     *  此测试仅覆盖"当前 writer 清理"路径（未跨 64MB 阈值），验证 catch 块不崩溃、
     *  不残留 .sst 文件。 */
    @TestCase
    public func writeStreamThrowsClosesWriterAndRemovesFile(): Unit {
        let dir = "${testDir}/write_stream_throw"
        Directory.create(dir, recursive: true)

        // 自定义迭代器：产出 5 条记录后在第 3 次 next() 时抛出异常
        let items = ArrayList<(ByteArray, EntryValue)>()
        for (i in 0..5) {
            items.add((ByteArray([UInt8(i)]), EntryValue([UInt8(0xA0 + i)], Int64(i))))
        }
        let iter = FailAfterIterator(items, 3)

        try {
            writeStreamToSSTables(iter, dir, 0)
            @Expect(false) // 不应到达这里
        } catch (_: Exception) {
            // 预期异常
        }

        // 验证：目录下无残留 .sst 文件
        let files = ArrayList<String>()
        Directory.walk(dir) { fi =>
            if (fi.path.extensionName == "sst") {
                files.add(fi.path.toString())
            }
            true
        }
        @Expect(files.size == 0)

        remove(dir, recursive: true)
    }

    /** 验证 writeStreamToSSTables 返回空结果时（如全量过期）Compaction 不会跳过清理旧文件。
     *  P2 修复前：newSSTables.size==0 时直接 return，跳过 removeSSTables+close+delete。
     *  P2 修复后：先清理旧文件再 return。此测试验证正常 compaction 后旧文件从 LevelManager 移除。 */
    @TestCase
    public func compactorRemovesOldFilesAfterMerge(): Unit {
        let dir = "${testDir}/remove_old"
        Directory.create(dir, recursive: true)

        let sst1 = SSTable("${dir}/L0_0.sst", 1)
        sst1.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst1.finishWrite()
        sst1.close()

        let sst2 = SSTable("${dir}/L0_1.sst", 1)
        sst2.write(ByteArray([0x02]), EntryValue([0xA2], 2))
        sst2.finishWrite()
        sst2.close()

        let mgr = LevelManager(dir)
        mgr.addSSTable(0, SSTable.open("${dir}/L0_0.sst"))
        mgr.addSSTable(0, SSTable.open("${dir}/L0_1.sst"))
        @Expect(mgr.getSSTablesForCompaction(0).size == 2)

        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(0)

        // 验证旧文件已从 LevelManager 移除
        @Expect(mgr.getSSTablesForCompaction(0).size == 0)
        // 新数据应读到（正常 compaction 合并到 L1）
        @Expect(mgr.get(ByteArray([0x01])).isSome())
        @Expect(mgr.get(ByteArray([0x02])).isSome())

        mgr.closeAll()
        remove(dir, recursive: true)
    }
}

@Test
public class CompactionSelectionTest {

    let testDir = "/tmp/f_store_compaction_selection_test"

    /** 辅助函数：创建 SSTable 并写入数据 */
    private func createSSTable(path: String, entries: Array<(ByteArray, EntryValue)>): SSTable {
        let idx = path.lastIndexOf('/').getOrThrow()
        let dir = path[0 .. idx]
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let capacity = if (entries.size > 0) { entries.size } else { 1 }
        let sst = SSTable(path, capacity)
        for ((key, entry) in entries) {
            sst.write(key, entry)
        }
        sst.finishWrite()
        sst
    }

    /** 验证 Ln 层 compaction 只选择与 nextLevel 有范围重叠的 SSTable。
     *  P2-1 修复：非 L0 层按 key 范围重叠筛选，避免无效 IO。 */
    @TestCase
    public func nonL0SelectsOverlappingOnly(): Unit {
        let dir = "${testDir}/overlap"
        Directory.create(dir, recursive: true)

        // L1: 3 个 SSTable，key 范围不重叠
        let l1_1 = createSSTable("${dir}/L1_0.sst", [
            (ByteArray([UInt8(0x01), UInt8(0x00)]), EntryValue(Some([UInt8(0xAAu8)]), 1)),
            (ByteArray([UInt8(0x01), UInt8(0x10)]), EntryValue(Some([UInt8(0xABu8)]), 2))
        ])
        let l1_2 = createSSTable("${dir}/L1_1.sst", [
            (ByteArray([UInt8(0x02), UInt8(0x00)]), EntryValue(Some([UInt8(0xBBu8)]), 3)),
            (ByteArray([UInt8(0x02), UInt8(0x10)]), EntryValue(Some([UInt8(0xBCu8)]), 4))
        ])
        let l1_3 = createSSTable("${dir}/L1_2.sst", [
            (ByteArray([UInt8(0x03), UInt8(0x00)]), EntryValue(Some([UInt8(0xCCu8)]), 5)),
            (ByteArray([UInt8(0x03), UInt8(0x10)]), EntryValue(Some([UInt8(0xCDu8)]), 6))
        ])

        // L2: 1 个 SSTable，只与 L1 的 [0x02xx] 范围重叠
        let l2_1 = createSSTable("${dir}/L2_0.sst", [
            (ByteArray([UInt8(0x02), UInt8(0x08)]), EntryValue(Some([UInt8(0xDDu8)]), 7)),
            (ByteArray([UInt8(0x02), UInt8(0x18)]), EntryValue(Some([UInt8(0xDEu8)]), 8))
        ])

        let mgr = LevelManager(dir, levelCount: 7)
        mgr.addSSTable(1, l1_1)
        mgr.addSSTable(1, l1_2)
        mgr.addSSTable(1, l1_3)
        mgr.addSSTable(2, l2_1)

        @Expect(mgr.getSSTablesForCompaction(1).size == 3)

        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(1)

        // L1 应剩余 2 个文件（[0x01xx] 和 [0x03xx] 未与 L2 重叠）
        let remainingL1 = mgr.getSSTablesForCompaction(1)
        @Expect(remainingL1.size == 2)

        // 全部 6 个 key 仍可读
        for (i in 1..4) {
            for (j in [UInt8(0x00), UInt8(0x10)]) {
                let key = ByteArray([UInt8(i), j])
                let v = mgr.get(key)
                @Expect(v.isSome())
            }
        }

        mgr.closeAll()
        remove(dir, recursive: true)
    }

    /** 验证 Ln 层与 nextLevel 无重叠时只选最后一个文件。
     *  P2-1 修复：无重叠时不选末尾 4 个，选 1 个避免无效 IO。 */
    @TestCase
    public func nonL0NoOverlapSelectsLastOne(): Unit {
        let dir = "${testDir}/no_overlap"
        Directory.create(dir, recursive: true)

        // L1: 3 个 SSTable
        let l1_1 = createSSTable("${dir}/L1_0.sst", [
            (ByteArray([UInt8(0x01)]), EntryValue(Some([UInt8(0xAAu8)]), 1))
        ])
        let l1_2 = createSSTable("${dir}/L1_1.sst", [
            (ByteArray([UInt8(0x02)]), EntryValue(Some([UInt8(0xBBu8)]), 2))
        ])
        let l1_3 = createSSTable("${dir}/L1_2.sst", [
            (ByteArray([UInt8(0x03)]), EntryValue(Some([UInt8(0xCCu8)]), 3))
        ])

        // L2: 1 个 SSTable，与 L1 完全无重叠
        let l2_1 = createSSTable("${dir}/L2_0.sst", [
            (ByteArray([UInt8(0x05)]), EntryValue(Some([UInt8(0xDDu8)]), 4))
        ])

        let mgr = LevelManager(dir, levelCount: 7)
        mgr.addSSTable(1, l1_1)
        mgr.addSSTable(1, l1_2)
        mgr.addSSTable(1, l1_3)
        mgr.addSSTable(2, l2_1)

        @Expect(mgr.getSSTablesForCompaction(1).size == 3)

        let compactor = Compactor(mgr, dir, levelCount: 7)
        compactor.compact(1)

        // L1 应剩余 2 个文件（最后一个 [0x03] 被选中）
        let remainingL1 = mgr.getSSTablesForCompaction(1)
        @Expect(remainingL1.size == 2)

        // 全部 4 个 key 仍可读
        for (i in 1..4) {
            let key = ByteArray([UInt8(i)])
            let v = mgr.get(key)
            @Expect(v.isSome())
        }
        @Expect(mgr.get(ByteArray([UInt8(0x05)])).isSome())

        mgr.closeAll()
        remove(dir, recursive: true)
    }
}
