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
package fountain::f_zip

import std.fs.{File, OpenMode}
import std.io.{InputStream, SeekPosition}

/**
 * 随机访问抽象：`ZipReader` 的全部解析逻辑只面向这个接口，
 * 两种构造（内存缓冲 / 文件 seek）的差别被压到"怎么读到字节"这一层。
 *
 * `openRange` 必须返回**独立游标**的流：`FileSource` 另开文件句柄，
 * `BufferSource` 在共享字节数组上开独立游标，因此多个 `open` 可以并发读。
 */
internal interface EntrySource {
    prop size: Int64
    func readAt(offset: Int64, dst: Array<Byte>): Int64
    func openRange(offset: Int64, length: Int64): InputStream
    func close(): Unit
}

/** 整块已读进内存的源（`ZipReader(input)`）。 */
internal class BufferSource <: EntrySource {
    private let data: Array<Byte>

    public init(data: Array<Byte>) {
        this.data = data
    }

    public prop size: Int64 {
        get() {
            data.size
        }
    }

    public func readAt(offset: Int64, dst: Array<Byte>): Int64 {
        if (offset < 0 || offset >= data.size || dst.size == 0) {
            return 0
        }
        let left = data.size - offset
        let n = if (dst.size < left) {
            dst.size
        } else {
            left
        }
        data.copyTo(dst, offset, 0, n)
        n
    }

    public func openRange(offset: Int64, length: Int64): InputStream {
        ArrayRangeInputStream(data, offset, length)
    }

    public func close(): Unit {}
}

/** 走 `File.seek` 的源（`ZipReader(path)`），不缓冲整个文件。 */
internal class FileSource <: EntrySource {
    private let path: String
    private var file: File
    private let fileLength: Int64
    private var closed: Bool = false

    public init(path: String) {
        this.path = path
        this.file = File(path, OpenMode.Read)
        this.fileLength = file.length
    }

    public prop size: Int64 {
        get() {
            fileLength
        }
    }

    public func readAt(offset: Int64, dst: Array<Byte>): Int64 {
        if (closed || offset < 0 || offset >= fileLength || dst.size == 0) {
            return 0
        }
        let left = fileLength - offset
        let want = if (dst.size < left) {
            dst.size
        } else {
            left
        }
        file.seek(Begin(offset))
        var got: Int64 = 0
        while (got < want) {
            let tmp = Array<Byte>(want - got, repeat: 0)
            let n = file.read(tmp)
            if (n <= 0) {
                break
            }
            tmp[0..n].copyTo(dst, 0, got, n)
            got += n
        }
        got
    }

    public func openRange(offset: Int64, length: Int64): InputStream {
        FileRangeInputStream(path, offset, length)
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            try {
                file.close()
            } catch (_: Exception) {}
        }
    }
}
