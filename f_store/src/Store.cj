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
 * - add/remove/ttl: WAL.append（IOUringStream 异步写）+ ConcurrentSkipListMap.add（CAS）
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

        // 从 WAL 恢复 MemTable
        let recovered = WALReader.recoverAll(walDir)
        this.memTableManager = MemTableManager()
        // 将恢复的数据写入 active MemTable
        let iter = recovered.iterator()
        while (let Some((key, entry)) <- iter.next()) {
            memTableManager.getActive().add(key, entry)
        }

        // 加载已有 SSTable
        this.levelManager = LevelManager(sstDir)
        levelManager.loadExisting()

        // 确定 WAL 起始序列号
        var startSeq: Int64 = 0
        if (recovered.approximateSize() > 0) {
            // 从恢复的数据中获取最大序列号
            let recoveryIter = recovered.iterator()
            while (let Some((_, entry)) <- recoveryIter.next()) {
                if (entry.sequence > startSeq) {
                    startSeq = entry.sequence
                }
            }
        }
        this.sequence = AtomicInt64(startSeq)
        this.closed = AtomicBool(false)

        // 创建新 WAL
        this.wal = WAL("${walDir}/wal_${startSeq}.wal", startSequence: startSeq + 1)

        // 进程退出时自动关闭
        atExit { => close() }
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
        // 查 active MemTable
        let activeResult = memTableManager.getActive().get(keyBytes)
        if (let Some(entry) <- activeResult) {
            return checkExpiryAndGet(entry)
        }
        // 查 immutable MemTable
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let immResult = imm.get(keyBytes)
            if (let Some(entry) <- immResult) {
                return checkExpiryAndGet(entry)
            }
        }
        // 查 LevelManager
        if (let Some(entry) <- levelManager.get(keyBytes)) {
            return checkExpiryAndGet(entry)
        }
        None
    }

    /** 前缀遍历：返回所有以 prefix 开头的键值对（含过期过滤） */
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
                let newBytes = Array<Byte>(i + 1, item: 0)
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

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // flush immutable MemTable（如果有）
        if (let Some(imm) <- memTableManager.getImmutable()) {
            let sstables = flushMemTable(imm, sstDir, 0)
            for (sst in sstables) {
                levelManager.addSSTable(0, sst)
            }
            memTableManager.clearImmutable()
        }
        // flush active MemTable
        let active = memTableManager.getActive()
        if (active.approximateSize() > 0) {
            let sstables = flushMemTable(active, sstDir, 0)
            for (sst in sstables) {
                levelManager.addSSTable(0, sst)
            }
        }
        // 关闭 WAL（内部先 sync 再关流）
        wal.sync()
        wal.close()
        // 关闭所有 SSTable
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
            if (let Some(oldExpire) <- oldEntry.expireAt) {
                if (oldExpire <= DateTime.now().toUnixTimeStamp().toNanoseconds()) {
                    return None // 旧值已过期
                }
            }
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

    /** 过期检查：过期或 tombstone 返回 None，否则返回 value */
    private func checkExpiryAndGet(entry: EntryValue): ?Array<Byte> {
        // tombstone
        if (entry.value.isNone()) {
            return None
        }
        // 过期检查
        if (let Some(expireAt) <- entry.expireAt) {
            if (expireAt <= DateTime.now().toUnixTimeStamp().toNanoseconds()) {
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
    }
}
