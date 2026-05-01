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

/** 层级管理：管理 L0~Ln 各层的 SSTable 列表，提供带过期检查的 get 查询
 *
 *  无锁设计：用 AtomicReference 替代 Mutex 保护每层的 SSTable 列表。
 *  - get/查询：原子加载列表快照，迭代无锁
 *  - add/remove：copy + CAS 原子替换
 *  - 写操作之间由调用方保证串行（flush/compaction 在单线程或互斥路径执行）
 */
class LevelManager {
    let sstDir: String
    let levels: Array<AtomicReference<ArrayList<SSTable>>>
    let levelCount: Int64
    /** 每层 SSTable 总大小缓存，避免 shouldCompact 遍历全量文件 */
    let levelSizes: Array<AtomicInt64>

    init(sstDir: String, levelCount!: Int64 = 7) {
        this.sstDir = sstDir
        this.levelCount = levelCount
        this.levels = Array<AtomicReference<ArrayList<SSTable>>>(levelCount){_ => 
            AtomicReference<ArrayList<SSTable>>(ArrayList<SSTable>())
        }
        this.levelSizes = Array<AtomicInt64>(levelCount){_ => AtomicInt64(0)}
    }

    /** 从 sstDir 加载已有 SSTable 文件 */
    func loadExisting(): Unit {
        if (!exists(sstDir)) {
            return
        }
        let files = SSTable.loadAll(sstDir)
        var maxSstIndex: Int64 = 0
        // 按 level 分组添加到各层（init 时无并发，直接 add）
        for (f in files) {
            let level = f.getMetadata().level
            if (level >= 0 && level < levelCount) {
                levels[level].load().add(f)
                levelSizes[level].fetchAdd(f.getMetadata().fileSize)
                // 更新最大 sstIndex，用于恢复 sstableFileSeq
                let idx = parseSSTIndexFromPath(f.getMetadata().filePath)
                if (idx > maxSstIndex) {
                    maxSstIndex = idx
                }
            } else {
                f.close()
            }
        }
        // 恢复全局 SSTable 序号，防止重启后文件名冲突
        if (maxSstIndex > 0) {
            sstableFileSeq.store(maxSstIndex)
        }
    }

    /** 从 L0 到 Ln 逐层查找 key，含过期检查 */
    func get(key: ByteArray): ?EntryValue {
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        get(key, now)
    }

    /** 从 L0 到 Ln 逐层查找 key，含过期检查（使用调用方传入的 now） */
    func get(key: ByteArray, now: Int64): ?EntryValue {
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
        let sstList = levels[level].load()
        if (level == 0) {
            // L0: 从末尾开始反向遍历（最新文件最后添加，优先命中）
            let count = sstList.size
            var i = count - 1
            while (i >= 0) {
                let sst = sstList[i]
                if (!sst.isClosed()) {
                    let entry = sst.get(key)
                    if (entry.isSome()) {
                        if (let Some(e) <- entry) {
                            return checkExpiry(e, now)
                        }
                    }
                }
                i--
            }
        } else {
            // Ln (n≥1): 按 metadata min/max 筛选范围匹配的 SSTable
            for (i in 0..sstList.size) {
                let sst = sstList[i]
                if (sst.isClosed()) {
                    continue
                }
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
        // copy + CAS 无锁添加
        while (true) {
            let oldList = levels[level].load()
            let newList = ArrayList<SSTable>()
            newList.add(all: oldList)
            newList.add(sst)
            if (levels[level].compareAndSwap(oldList, newList)) {
                levelSizes[level].fetchAdd(sst.getMetadata().fileSize)
                break
            }
        }
    }

    /** 从指定层移除一批 SSTable，通过对象引用匹配 */
    func removeSSTables(level: Int64, toRemove: ArrayList<SSTable>): Unit {
        if (level < 0 || level >= levelCount) {
            return
        }
        // copy + CAS 无锁移除
        while (true) {
            let oldList = levels[level].load()
            let newList = ArrayList<SSTable>()
            for (sst in oldList) {
                var shouldKeep = true
                for (rm in toRemove where refEq(sst, rm)) {
                    shouldKeep = false
                    break
                }
                if (shouldKeep) {
                    newList.add(sst)
                }
            }
            if (levels[level].compareAndSwap(oldList, newList)) {
                // 递减已移除文件的 size（CAS 成功后才扣减）
                for (rm in toRemove) {
                    levelSizes[level].fetchAdd(-rm.getMetadata().fileSize)
                }
                break
            }
        }
    }

    /** 获取指定层用于 Compaction 的 SSTable 快照 */
    func getSSTablesForCompaction(level: Int64): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
        if (level < 0 || level >= levelCount) {
            return result
        }
        let sstList = levels[level].load()
        for (sst in sstList) {
            result.add(sst)
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

    /** 获取指定层与 [min, max] 范围重叠的 SSTable。max 为 None 表示无上界。
     *  L0：key 范围全重叠，直接返回全部文件（跳过 metadata 读取）。
     *  Ln (n≥1)：按 minKey/maxKey 做范围筛选。 */
    func getOverlappingSSTables(level: Int64, min: ByteArray, max: ?ByteArray): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
        if (level < 0 || level >= levelCount) {
            return result
        }
        let sstList = levels[level].load()
        if (level == 0) {
            // L0: key 范围全重叠，全部返回
            for (sst in sstList) {
                result.add(sst)
            }
        } else {
            // Ln (n≥1): 按 minKey/maxKey 做范围筛选
            for (sst in sstList) {
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
        let sstList = levels[level].load()
        let count = sstList.size
        if (level == 0) {
            return count >= 4
        }
        // Ln (n≥1): 总大小 >= 10^n MB（使用缓存 levelSizes，免遍历）
        let sizeLimitMB = 10 ** UInt64(level)
        let totalMB = levelSizes[level].load() / (1024 * 1024)
        totalMB >= sizeLimitMB
    }

    /** 关闭所有 SSTable */
    func closeAll(): Unit {
        for (level in 0..levelCount) {
            let sstList = levels[level].load()
            for (sst in sstList) {
                try {
                    sst.close()
                } catch (_: Exception) {}
            }
        }
    }

    /** 调试用：返回各层 SSTable 数量摘要 */
    func levelSummary(): String {
        var s = ""
        for (level in 0..levelCount) {
            let sstList = levels[level].load()
            let cnt = sstList.size
            if (cnt > 0) {
                if (s.size > 0) {
                    s += ", "
                }
                s += "L${level}:${cnt}"
            }
        }
        s
    }
}
