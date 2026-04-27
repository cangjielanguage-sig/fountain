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
    private let file: File
    private let stream: IOStream
    let sequence: AtomicInt64
    let appendCount: AtomicInt64
    let closed: AtomicBool
    private let syncInterval: Int64

    init(path: String, startSequence!: Int64 = 0) {
        // 确保目录存在
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.file = File(path, OpenMode.ReadWrite)
        @When[os == "Linux"]
        let stream = IOUringStream(Int32(file.fileDescriptor.fileHandle))
        @When[os != "Linux"]
        let stream = file
        this.stream = stream
        this.sequence = AtomicInt64(startSequence)
        this.appendCount = AtomicInt64(0)
        this.closed = AtomicBool(false)
        this.syncInterval = 100
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        let record = WALRecord(seq, key, value, expireAt: expireAt)
        let encoded = record.encode()
        stream.write(encoded)
        let count = appendCount.incrFetch()
        if (count % syncInterval == 0) {
            sync()
        }
        seq
    }

    func sync(): Unit {
        if (!closed.load()) {
            stream.flush()
        }
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        sync()
        if (let r: Resource <- stream && !r.isClosed()) {
            r.close()
        }
        if (let r: Resource <- file && !r.isClosed()) {
            r.close()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
