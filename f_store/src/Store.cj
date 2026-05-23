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

/** LSM-Tree 键值存储引擎。
 *
 * 关键路径无锁设计：
 * - add/remove/ttl: WAL.append（File 同步写）+ ConcurrentSkipListMap.add（CAS）
 * - get: ConcurrentSkipListMap.get（无锁读）+ SSTable 点查询
 * - maybeFlush: 仅 swap 时短暂持 flushLock
 */
public class Store <: Resource {
    private let path: String
    private let walDir: String
    private let sstDir: String
    private let memTableManager: MemTableManager
    private let wal: WAL
    private let levelManager: LevelManager
    private let sequence: AtomicInt64
    private let closed: AtomicBool
    private let memFlushThreshold: Int64
    private let compactor: Compactor

    /** 从路径打开或创建 Store */
    public init(path: Path) {
        this(path.toString())
    }

    /** 从路径打开或创建 Store */
    public init(path: String) {
        this.path = path
        this.walDir = "${path}/wal"
        this.sstDir = "${path}/sst"
        this.memFlushThreshold = 8 * 1024 * 1024 // 8MB

        // 确保目录存在
        if (!exists(walDir)) {
            Directory.create(walDir, recursive: true)
        }
        if (!exists(sstDir)) {
            Directory.create(sstDir, recursive: true)
        }

        // 从 WAL 恢复 MemTable，同时找出最大序列号
        let recovered = WALReader.recoverAll(walDir)
        this.memTableManager = MemTableManager()
        var startSeq: Int64 = 0
        let iter = recovered.iterator()
        while (let Some((key, entry)) <- iter.next()) {
            memTableManager.getActive().add(key, entry)
            if (entry.sequence > startSeq) {
                startSeq = entry.sequence
            }
        }

        // 加载已有 SSTable
        this.levelManager = LevelManager(sstDir)
        levelManager.loadExisting()

        this.sequence = AtomicInt64(startSeq)
        this.closed = AtomicBool(false)

        // 清理已恢复的旧 WAL 文件（数据已在 MemTable 中）
        cleanupOldWALFiles(walDir)

        // 创建新 WAL
        this.wal = WAL("${walDir}/wal_${startSeq}.wal", startSequence: startSeq + 1)

        // 创建 Compactor
        this.compactor = Compactor(levelManager, sstDir)

        // 进程退出时自动关闭
        atExit { => 
            if(!isClosed()){
                close() 
            }
        }

        // 启动 Compaction（放在 init 最后，确保所有状态就绪）
        compactor.start()
    }

    /** 添加键值对 */
    public func add(key: Array<Byte>, value: Array<Byte>): ?Array<Byte> {
        guardOpen()
        let seq = wal.append(key, value)
        let entry = EntryValue(value, seq)
        let old = memTableManager.getActive().add(ByteArray(key), entry)
        maybeFlush()
        if (let Some(oldEntry) <- old) {
            return oldEntry.value
        }
        None
    }

    /** 添加带过期时间的键值对 */
    public func add(key: Array<Byte>, value: Array<Byte>, expireAt: DateTime): ?Array<Byte> {
        addWithExpire(key, value, expireAt.toUnixTimeStamp().toNanoseconds())
    }

    /** 添加带 TTL 的键值对 */
    public func add(key: Array<Byte>, value: Array<Byte>, expire: Duration): ?Array<Byte> {
        addWithExpire(key, value, DateTime.now().toUnixTimeStamp().toNanoseconds() + expire.toNanoseconds())
    }

    /** 强制将 WAL 缓冲区写入磁盘（确保崩溃时可恢复） */
    public func syncWAL(): Unit {
        guardOpen()
        wal.sync()
    }

    /** 设置/更新已有 key 的过期时间（指定绝对时间） */
    public func ttl(key: Array<Byte>, expireAt: DateTime): Unit {
        ttlInternal(key, expireAt.toUnixTimeStamp().toNanoseconds())
    }

    /** 设置/更新已有 key 的过期时间（指定相对时长） */
    public func ttl(key: Array<Byte>, expire: Duration): Unit {
        ttlInternal(key, DateTime.now().toUnixTimeStamp().toNanoseconds() + expire.toNanoseconds())
    }

    /** 删除键，返回旧值 */
    public func remove(key: Array<Byte>): ?Array<Byte> {
        guardOpen()
        let seq = wal.append(key, None)
        let entry = EntryValue(None, seq)
        let old = memTableManager.getActive().add(ByteArray(key), entry)
        maybeFlush()
        if (let Some(oldEntry) <- old) {
            return oldEntry.value
        }
        None
    }

    /** 获取键值，含过期检查 */
    public func get(key: Array<Byte>): ?Array<Byte> {
        guardOpen()
        let keyBytes = ByteArray(key)
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        // 查 active MemTable
        let activeResult = memTableManager.getActive().get(keyBytes)
        if (let Some(entry) <- activeResult) {
            return checkExpiryAndGet(entry, now)
        }
        // 查 immutable MemTable
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let immResult = imm.get(keyBytes)
            if (let Some(entry) <- immResult) {
                return checkExpiryAndGet(entry, now)
            }
        }
        // 查 LevelManager
        if (let Some(entry) <- levelManager.get(keyBytes, now)) {
            return checkExpiryAndGet(entry, now)
        }
        None
    }

    /** 检查键是否存在（已考虑过期和 tombstone） */
    public func contains(key: Array<Byte>): Bool {
        guardOpen()
        let keyBytes = ByteArray(key)
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        // 查 active MemTable
        let activeResult = memTableManager.getActive().get(keyBytes)
        if (let Some(entry) <- activeResult) {
            return entryIsAlive(entry, now)
        }
        // 查 immutable MemTable
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let immResult = imm.get(keyBytes)
            if (let Some(entry) <- immResult) {
                return entryIsAlive(entry, now)
            }
        }
        // 查 LevelManager
        if (let Some(entry) <- levelManager.get(keyBytes, now)) {
            return entryIsAlive(entry, now)
        }
        false
    }

    /** 前缀遍历：返回所有以 prefix 开头的键值对（含过期过滤）。
     *  SSTable 遍历使用独立 File 句柄，详见 README.md 「SSTable 迭代器独立 File 句柄设计」。
     */
    public func prefix(prefix: Array<Byte>): PrefixIterator {
        guardOpen()
        let prefixBytes = ByteArray(prefix)
        let prefixEnd = computePrefixEnd(prefixBytes)
        let sources = ArrayList<PeekableIterator<(ByteArray, EntryValue)>>()

        // 1. Active MemTable
        sources.add(PeekableIterator(memTableManager.getActive().tailer(prefixBytes)))
        // 2. Immutable MemTable
        if (let Some(imm) <- memTableManager.getImmutable()) {
            sources.add(PeekableIterator(imm.tailer(prefixBytes)))
        }
        // 3. SSTables: 范围内各 SSTable 用 tailer 从 prefix 开始遍历
        let sstables = levelManager.getSSTablesInRange(prefixBytes, prefixEnd)
        for (sst in sstables) {
            sources.add(PeekableIterator(sst.tailer(prefixBytes)))
        }

        PrefixIterator(prefixBytes, sources)
    }

    /** 计算前缀上界：prefix 的"下一个"key，用于范围查询。全 0xFF 返回 None（无上界） */
    private func computePrefixEnd(prefix: ByteArray): ?ByteArray {
        let bytes = prefix.bytes
        var i = bytes.size - 1
        while (i >= 0) {
            if (bytes[i] < 0xFF) {
                let newBytes = Array<Byte>(i + 1, repeat: 0u8)
                for (j in 0..i) {
                    newBytes[j] = bytes[j]
                }
                newBytes[i] = bytes[i] + 1
                return Some(ByteArray(newBytes))
            }
            i -= 1
        }
        None
    }

    public func isClosed(): Bool {
        closed.load()
    }

    public func levelSummary(): String {
        levelManager.levelSummary()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // 停止 Compactor
        compactor.stop()
        // 1. flush 已有的 immutable MemTable（如果有），释放 immutable 槽位
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let sstables = flushMemTable(imm, sstDir, 0)
            for (sst in sstables) {
                levelManager.addSSTable(0, sst)
            }
            memTableManager.clearImmutable()
        }
        // 2. swapActive → 将当前 active 原子切换为 immutable（flushLock 保护）
        //    新 active 为空，任何已通过 guardOpen 的并发 add() 写入新 active
        //    （数据在 WAL 中，恢复时可找回）
        if (let Some(imm) <- memTableManager.swapActive()) {
            let sstables = flushMemTable(imm, sstDir, 0)
            for (sst in sstables) {
                levelManager.addSSTable(0, sst)
            }
            memTableManager.clearImmutable()
        }
        // 2a. 二次 swap：flush 期间并发 add() 可能写入新 active
        //     此操作非阻塞——无并发写则 swapActive() 返回 None 直接跳过
        if (let Some(imm2) <- memTableManager.swapActive()) {
            let sstables2 = flushMemTable(imm2, sstDir, 0)
            for (sst in sstables2) {
                levelManager.addSSTable(0, sst)
            }
            memTableManager.clearImmutable()
        }
        // 3. WAL sync + close
        wal.sync()
        wal.close()
        // 4. 关闭所有 SSTable
        levelManager.closeAll()
    }

    // ================================================================
    // 内部方法
    // ================================================================

    /** 添加带过期时间的键值对（纳秒时间戳） */
    private func addWithExpire(key: Array<Byte>, value: Array<Byte>, expireAt: Int64): ?Array<Byte> {
        guardOpen()
        let seq = wal.append(key, value, expireAt: expireAt)
        let entry = EntryValue(value, seq, expireAt: expireAt)
        let old = memTableManager.getActive().add(ByteArray(key), entry)
        maybeFlush()
        if (let Some(oldEntry) <- old) {
            return oldEntry.value
        }
        None
    }

    /** ttl 内部实现（纳秒时间戳） */
    private func ttlInternal(key: Array<Byte>, expireAt: Int64): Unit {
        guardOpen()
        let keyBytes = ByteArray(key)
        // 查找当前值
        let entry = lookupEntry(keyBytes)
        if (entry.isNone()) {
            return
        }
        if (let Some(e) <- entry) {
            if (e.value.isNone()) {
                return // tombstone
            }
            // 用当前 value + 新 expireAt 重新写入
            let seq = wal.append(key, e.value ?? [], expireAt: expireAt)
            let newEntry = EntryValue(e.value, seq, expireAt: expireAt)
            memTableManager.getActive().add(keyBytes, newEntry)
        }
    }

    /** 检查 Store 是否已关闭 */
    private func guardOpen(): Unit {
        if (closed.load()) {
            throw StoreClosedException()
        }
    }

    /** 查找 Entry（不做过期检查），供 ttl 使用 */
    private func lookupEntry(key: ByteArray): ?EntryValue {
        // 查 active MemTable
        let activeResult = memTableManager.getActive().get(key)
        if (activeResult.isSome()) {
            return activeResult
        }
        // 查 immutable MemTable
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let immResult = imm.get(key)
            if (immResult.isSome()) {
                return immResult
            }
        }
        // 查 LevelManager
        levelManager.get(key)
    }

    /** 过期检查：过期或 tombstone 返回 false，否则返回 true */
    private func entryIsAlive(entry: EntryValue, now: Int64): Bool {
        if (entry.value.isNone()) {
            return false
        }
        if (let Some(expireAt) <- entry.expireAt) {
            if (expireAt <= now) {
                return false
            }
        }
        true
    }

    /** 过期检查：过期或 tombstone 返回 None，否则返回 value */
    private func checkExpiryAndGet(entry: EntryValue, now: Int64): ?Array<Byte> {
        // tombstone
        if (entry.value.isNone()) {
            return None
        }
        // 过期检查
        if (let Some(expireAt) <- entry.expireAt) {
            if (expireAt <= now) {
                return None
            }
        }
        entry.value
    }

    /** 超过阈值时自动刷盘 */
    private func maybeFlush(): Unit {
        if (memTableManager.getActive().approximateSize() < memFlushThreshold) {
            return
        }
        if (let Some(table) <- memTableManager.swapActive()) {
            let sstables = flushMemTable(table, sstDir, 0)
            for (sst in sstables) {
                levelManager.addSSTable(0, sst)
            }
            memTableManager.clearImmutable()
        }
        // 刷盘完成后清理已轮转的旧 WAL 文件（它们的数据已持久化到 SSTable）
        cleanupRotatedWALFiles()
    }

    /** 清理 WAL 轮转产生的旧文件（数据已通过 flush 持久化到 SSTable） */
    private func cleanupRotatedWALFiles(): Unit {
        let oldFiles = wal.takeOldFiles()
        for (p in oldFiles) {
            try {
                if (exists(p)) {
                    remove(p)
                }
            } catch (_: Exception) {}
        }
    }
}
