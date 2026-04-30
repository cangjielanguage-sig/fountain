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
    private var stream: IOStream
    let sequence: AtomicInt64
    let closed: AtomicBool
    private let syncInterval: Int64
    private var appendCount: Int64
    private var currentFileSize: Int64
    private let maxFileSize: Int64
    private var walPath: String
    private let walDir: String
    /** 已关闭的旧 WAL 文件路径列表（等待清理） */
    private let oldFiles: ArrayList<String>

    init(path: String, startSequence!: Int64 = 0, maxFileSize!: Int64 = 64 * 1024 * 1024) {
        // 确保目录存在
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.walPath = path
        this.walDir = parentDir.toString()
        this.file = File(path, OpenMode.ReadWrite)
        @When[os == "Linux"]
        let s = IOUringStream(Int32(file.fileDescriptor.fileHandle))
        @When[os != "Linux"]
        let s: IOStream = file
        this.stream = s
        this.sequence = AtomicInt64(startSequence)
        this.closed = AtomicBool(false)
        this.syncInterval = 100
        this.appendCount = 0
        this.currentFileSize = 0
        this.maxFileSize = maxFileSize
        this.oldFiles = ArrayList<String>()
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        let record = WALRecord(seq, key, value, expireAt: expireAt)
        let encoded = record.encode()
        stream.write(encoded)
        currentFileSize += Int64(encoded.size)
        appendCount++
        if (appendCount % syncInterval == 0) {
            sync()
        }
        if (currentFileSize >= maxFileSize) {
            rotate()
        }
        seq
    }

    func sync(): Unit {
        if (!closed.load()) {
            stream.flush()
        }
    }

    /** 返回已关闭的旧 WAL 文件列表（等待清理），并清空内部列表 */
    func takeOldFiles(): ArrayList<String> {
        let result = ArrayList<String>()
        for (p in oldFiles) {
            result.add(p)
        }
        oldFiles.clear()
        result
    }

    private func rotate(): Unit {
        // sync + close 当前文件
        stream.flush()
        if (let r: Resource <- stream && !r.isClosed()) {
            r.close()
        }
        if (!file.isClosed()) {
            file.close()
        }
        oldFiles.add(walPath)

        // 用当前 sequence 创建新 WAL 文件
        let startSeq = sequence.load()
        let newPath = "${walDir}/wal_${startSeq}.wal"
        let newFile = File(newPath, OpenMode.ReadWrite)
        @When[os == "Linux"]
        let newStream = IOUringStream(Int32(newFile.fileDescriptor.fileHandle))
        @When[os != "Linux"]
        let newStream: IOStream = newFile
        this.file = newFile
        this.stream = newStream
        this.walPath = newPath
        this.currentFileSize = 0
        this.appendCount = 0
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        sync()
        if (let r: Resource <- stream && !r.isClosed()) {
            r.close()
        }
        if (!file.isClosed()) {
            file.close()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
