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
}
