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

/** 后台 Compaction 线程：定期检查各级是否需要合并，执行多路归并写新 SSTable */
class Compactor {
    let levelManager: LevelManager
    let sstDir: String
    let levelCount: Int64
    let running: AtomicBool
    let stopSignal: AtomicBool
    private var compactionThread: ?Future<Unit>

    init(levelManager: LevelManager, sstDir: String, levelCount!: Int64 = MAX_LEVEL) {
        this.levelManager = levelManager
        this.sstDir = sstDir
        this.levelCount = levelCount
        this.running = AtomicBool(false)
        this.stopSignal = AtomicBool(false)
        this.compactionThread = None
    }

    /** 启动后台 compaction 线程 */
    func start(): Unit {
        if (!running.compareAndSwap(false, true)) {
            return
        }
        stopSignal.store(false)
        let fut = spawn {
            runLoop()
            running.store(false)
        }
        compactionThread = Some(fut)
    }

    /** 停止 compaction 线程并等待结束 */
    func stop(): Unit {
        stopSignal.store(true)
        if (let Some(f) <- compactionThread) {
            try {
                f.get()
            } catch (_: Exception) {}
            compactionThread = None
        }
    }

    /** 是否正在运行 */
    func isRunning(): Bool {
        running.load()
    }

    /** 后台线程主循环 */
    func runLoop(): Unit {
        while (!stopSignal.load()) {
            var didWork = false
            for (level in 0..(levelCount - 1)) {
                if (stopSignal.load()) {
                    return
                }
                if (levelManager.shouldCompact(level)) {
                    try {
                        compact(level)
                        didWork = true
                    } catch (_: Exception) {
                        // Compaction 失败不影响正常读写，继续下一轮
                    }
                }
            }
            if (!didWork) {
                // 没有工作可做，休眠 100ms
                try {
                    sleep(Duration.millisecond * 100)
                } catch (_: Exception) {}
            }
        }
    }

    /** 执行一次 Compaction：将 level 层的 SSTable 与 level+1 层合并 */
    func compact(level: Int64): Unit {
        if (level < 0 || level >= levelCount - 1) {
            return
        }
        let nextLevel = level + 1
        let isBottomLevel = (nextLevel >= levelCount - 1)

        // 1. 获取 level 层需要 Compaction 的 SSTable
        let levelSSTables = levelManager.getSSTablesForCompaction(level)
        if (levelSSTables.size == 0) {
            return
        }
        // 从末尾开始选（新文件在末尾，数据最新），最多 4 个
        let selectedSSTables = ArrayList<SSTable>()
        if (level == 0) {
            // L0: key 范围全重叠，从末尾选最多 4 个
            let pickCount = if (levelSSTables.size > 4) { 4 } else { levelSSTables.size }
            for (i in (levelSSTables.size - pickCount)..levelSSTables.size) {
                selectedSSTables.add(levelSSTables[i])
            }
        } else {
            // Ln (n≥1): SSTable 之间 key 范围不重叠
            // 选择与 nextLevel 有范围重叠的文件，避免无效 IO
            let nextLevelSSTables = levelManager.getSSTablesForCompaction(nextLevel)
            if (nextLevelSSTables.size > 0) {
                for (sst in levelSSTables) {
                    let meta = sst.getMetadata()
                    var overlaps = false
                    for (ns in nextLevelSSTables) {
                        let nm = ns.getMetadata()
                        if (!(meta.maxKey < nm.minKey || meta.minKey > nm.maxKey)) {
                            overlaps = true
                            break
                        }
                    }
                    if (overlaps) {
                        selectedSSTables.add(sst)
                    }
                }
            }
            if (selectedSSTables.size == 0) {
                // 无重叠：选一个文件（从末尾选，逐步推进 compaction 边界）
                selectedSSTables.add(levelSSTables[levelSSTables.size - 1])
            }
        }
        if (selectedSSTables.size == 0) {
            return
        }

        // 2. 计算 selected SSTable 的 key 范围
        var minKey: ?ByteArray = None
        var maxKey: ?ByteArray = None
        for (sst in selectedSSTables) {
            let meta = sst.getMetadata()
            if (minKey.isNone() || meta.minKey < minKey.getOrThrow()) {
                minKey = Some(meta.minKey)
            }
            if (maxKey.isNone() || meta.maxKey > maxKey.getOrThrow()) {
                maxKey = Some(meta.maxKey)
            }
        }
        if (minKey.isNone() || maxKey.isNone()) {
            return
        }

        // 3. 获取 nextLevel 中范围重叠的 SSTable
        let overlappingSSTables = levelManager.getOverlappingSSTables(nextLevel, minKey.getOrThrow(), Some(maxKey.getOrThrow()))

        // 4. 构建多路归并迭代器
        // try 块覆盖 sources 构建，确保异常时已创建的迭代器 FD 被 finally 关闭
        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()
        try {
            for (sst in selectedSSTables) {
                sources.add(PeekableIterator(sst.iterator()))
            }
            for (sst in overlappingSSTables) {
                sources.add(PeekableIterator(sst.iterator()))
            }

            let merger = SSTableMerger(sources, isBottomLevel: isBottomLevel)

            // 5. 归并写入新 SSTable
            let newSSTables = writeStreamToSSTables(merger, sstDir, nextLevel)

            if (newSSTables.size > 0) {
                // 6. 原子替换：先加新 SSTable，再删旧的（并发读取安全：优先看到新数据）
                for (sst in newSSTables) {
                    levelManager.addSSTable(nextLevel, sst)
                }
            }
            // 清理旧文件（全量过期时 newSSTables 为空，旧文件仍需删除）
            levelManager.removeSSTables(level, selectedSSTables)
            levelManager.removeSSTables(nextLevel, overlappingSSTables)
            for (sst in selectedSSTables) {
                try {
                    sst.close()
                    remove(sst.getMetadata().filePath)
                } catch (_: Exception) {}
            }
            for (sst in overlappingSSTables) {
                try {
                    sst.close()
                    remove(sst.getMetadata().filePath)
                } catch (_: Exception) {}
            }

            if (newSSTables.size == 0) {
                return
            }
        } finally {
            // 关闭所有源迭代器，防止异常时 FD 泄漏。
            // 正常路径下迭代器已耗尽自动关闭（close 为幂等操作）。
            for (src in sources) {
                try {
                    src.close()
                } catch (_: Exception) {}
            }
        }
    }
}
