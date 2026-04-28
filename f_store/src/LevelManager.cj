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

/** 层级管理：管理 L0~Ln 各层的 SSTable 列表，提供带过期检查的 get 查询 */
class LevelManager {
    let sstDir: String
    let levels: Array<ArrayList<SSTable>>
    let levelCount: Int64
    let levelLocks: Array<Mutex>

    init(sstDir: String, levelCount!: Int64 = 7) {
        this.sstDir = sstDir
        this.levelCount = levelCount
        this.levels = Array<ArrayList<SSTable>>(levelCount, repeat: ArrayList<SSTable>())
        this.levelLocks = Array<Mutex>(levelCount, repeat: Mutex())
    }

    /** 从 sstDir 加载已有 SSTable 文件 */
    func loadExisting(): Unit {
        if (!exists(sstDir)) {
            return
        }
        let files = SSTable.loadAll(sstDir)
        for (f in files) {
            let level = f.getMetadata().level
            if (level >= 0 && level < levelCount) {
                levels[level].add(f)
            } else {
                f.close()
            }
        }
    }

    /** 从 L0 到 Ln 逐层查找 key，含过期检查 */
    func get(key: ByteArray): ?EntryValue {
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        for (level in 0..levelCount) {
            let result = getInLevel(level, key, now)
            if (result.isSome()) {
                return result
            }
        }
        None
    }

    /** 在指定层查找 key */
    private func getInLevel(level: Int64, key: ByteArray, now: Int64): ?EntryValue {
        synchronized(levelLocks[level]) {
            let sstList = levels[level]
            if (level == 0) {
                // L0: 遍历所有 SSTable（无序，可能有重叠）
                for (i in 0..sstList.size) {
                    let entry = sstList[i].get(key)
                    if (entry.isSome()) {
                        if (let Some(e) <- entry) {
                            return checkExpiry(e, now)
                        }
                    }
                }
            } else {
                // Ln (n≥1): 按 metadata min/max 筛选范围匹配的 SSTable
                for (i in 0..sstList.size) {
                    let sst = sstList[i]
                    let meta = sst.getMetadata()
                    if (key < meta.minKey || key > meta.maxKey) {
                        continue
                    }
                    let entry = sst.get(key)
                    if (entry.isSome()) {
                        if (let Some(e) <- entry) {
                            return checkExpiry(e, now)
                        }
                    }
                }
            }
        }
        None
    }

    /** 过期检查：tombstone 或已过期返回 None，否则返回 entry */
    private func checkExpiry(entry: EntryValue, now: Int64): ?EntryValue {
        // 已过期
        if (let Some(ea) <- entry.expireAt) {
            if (ea <= now) {
                return None
            }
        }
        // tombstone
        if (entry.value.isNone()) {
            return None
        }
        Some(entry)
    }

    /** 添加 SSTable 到指定层 */
    func addSSTable(level: Int64, sst: SSTable): Unit {
        if (level < 0 || level >= levelCount) {
            return
        }
        synchronized(levelLocks[level]) {
            levels[level].add(sst)
        }
    }

    /** 从指定层移除一批 SSTable，通过对象引用匹配 */
    func removeSSTables(level: Int64, toRemove: ArrayList<SSTable>): Unit {
        if (level < 0 || level >= levelCount) {
            return
        }
        synchronized(levelLocks[level]) {
            let newList = ArrayList<SSTable>()
            for (sst in levels[level]) {
                var shouldKeep = true
                for (rm in toRemove where refEq(sst, rm)) {
                    shouldKeep = false
                    break
                }
                if (shouldKeep) {
                    newList.add(sst)
                }
            }
            levels[level].clear()
            levels[level].add(all: newList)
        }
    }

    /** 获取指定层用于 Compaction 的 SSTable 快照 */
    func getSSTablesForCompaction(level: Int64): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
        if (level < 0 || level >= levelCount) {
            return result
        }
        synchronized(levelLocks[level]) {
            for (sst in levels[level]) {
                result.add(sst)
            }
        }
        result
    }

    /** 获取所有层与 [min, max] 范围重叠的 SSTable。max 为 None 表示无上界 */
    func getSSTablesInRange(min: ByteArray, max: ?ByteArray): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
        for (level in 0..levelCount) {
            result.add(all: getOverlappingSSTables(level, min, max))
        }
        result
    }

    /** 获取指定层与 [min, max] 范围重叠的 SSTable。max 为 None 表示无上界 */
    func getOverlappingSSTables(level: Int64, min: ByteArray, max: ?ByteArray): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
        if (level < 0 || level >= levelCount) {
            return result
        }
        synchronized(levelLocks[level]) {
            for (sst in levels[level]) {
                let meta = sst.getMetadata()
                // 重叠条件: (max 为 None 或 sst.minKey <= max) && sst.maxKey >= min
                let withinMax = max.isNone() || meta.minKey <= max.getOrThrow()
                if (withinMax && meta.maxKey >= min) {
                    result.add(sst)
                }
            }
        }
        result
    }

    /** 判断指定层是否需要 Compaction */
    func shouldCompact(level: Int64): Bool {
        if (level < 0 || level >= levelCount) {
            return false
        }
        synchronized(levelLocks[level]) {
            let count = levels[level].size
            if (level == 0) {
                return count >= 4
            }
            // Ln (n≥1): 总大小 >= 10^n MB
            let sizeLimitMB = pow10(level)
            var totalSize: Int64 = 0
            for (sst in levels[level]) {
                // 用 entryCount 近似估算大小
                totalSize += sst.getMetadata().entryCount * 100
            }
            let totalMB = totalSize / (1024 * 1024)
            totalMB >= sizeLimitMB
        }
    }

    /** 关闭所有 SSTable */
    func closeAll(): Unit {
        for (level in 0..levelCount) {
            synchronized(levelLocks[level]) {
                for (sst in levels[level]) {
                    try {
                        sst.close()
                    } catch (_: Exception) {}
                }
                levels[level].clear()
            }
        }
    }

    /** 计算 10^n（MB 单位阈值） */
    private func pow10(n: Int64): Int64 {
        var result: Int64 = 1
        for (_ in 0..n) {
            result *= 10
        }
        result
    }
}
