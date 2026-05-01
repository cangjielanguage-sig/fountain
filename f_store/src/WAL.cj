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

class WAL <: Resource {
    private var file: File
    let sequence: AtomicInt64
    let closed: AtomicBool
    private let syncInterval: Int64
    private let appendCount: AtomicInt64
    private let currentFileSize: AtomicInt64
    private let maxFileSize: Int64
    private var walPath: String
    private let walDir: String
    /** 已关闭的旧 WAL 文件路径列表（等待清理） */
    private let oldFiles: ArrayList<String>
    /** 保护 oldFiles 并发访问（rotate vs takeOldFiles） */
    private let oldFilesLock: Mutex
    /** 保护 append 中 file.write + rotate 的原子性 */
    private let appendLock: Mutex

    init(path: String, startSequence!: Int64 = 0, maxFileSize!: Int64 = 64 * 1024 * 1024) {
        // 确保目录存在
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.walPath = path
        this.walDir = parentDir.toString()
        this.file = File(path, OpenMode.ReadWrite)
        this.sequence = AtomicInt64(startSequence)
        this.closed = AtomicBool(false)
        this.syncInterval = 100
        this.appendCount = AtomicInt64(0)
        this.currentFileSize = AtomicInt64(0)
        this.maxFileSize = maxFileSize
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        let record = WALRecord(seq, key, value, expireAt: expireAt)
        let encoded = record.encode()
        // 用 Mutex 保护 file.write + rotate + sync 的原子性，防止与 close 竞态
        synchronized (appendLock) {
            // 获取锁后再次检查 closed（可能在等待锁时 close() 已执行）
            if (closed.load()) {
                throw StoreClosedException()
            }
            // 检查写入当前记录后的文件大小是否超限，超限则先 rotate 再写入新文件
            if (currentFileSize.load() + Int64(encoded.size) > maxFileSize) {
                rotate()
            }
            // 始终同步写入文件（数据到 OS page cache，进程崩溃可恢复）
            file.write(encoded)
            currentFileSize.fetchAdd(Int64(encoded.size))
            // fsync 锁内执行，确保与 close 互斥
            if (appendCount.incrFetch() % syncInterval == 0) {
                file.flush()
            }
        }
        seq
    }

    func sync(): Unit {
        synchronized (appendLock) {
            if (!closed.load()) {
                file.flush()
            }
        }
    }

    /** 返回已关闭的旧 WAL 文件路径列表（等待清理），并清空内部列表 */
    func takeOldFiles(): ArrayList<String> {
        synchronized (oldFilesLock) {
            let result = ArrayList<String>()
            for (p in oldFiles) {
                result.add(p)
            }
            oldFiles.clear()
            result
        }
    }

    private func rotate(): Unit {
        // sync（flush 缓冲区） + close 当前文件
        sync()
        if (!file.isClosed()) {
            file.close()
        }
        // 将旧路径加入待清理列表
        synchronized (oldFilesLock) {
            oldFiles.add(walPath)
        }

        // 用当前 sequence 创建新 WAL 文件
        let startSeq = sequence.load()
        let newPath = "${walDir}/wal_${startSeq}.wal"
        this.file = File(newPath, OpenMode.ReadWrite)
        this.walPath = newPath
        this.currentFileSize.store(0)
        this.appendCount.store(0)
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // 用 appendLock 确保在 append 中无正在进行的 file.write
        synchronized (appendLock) {
            // 强制 fsync 确保数据落盘（绕过 sync 的 closed 检查）
            file.flush()
            if (!file.isClosed()) {
                file.close()
            }
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
