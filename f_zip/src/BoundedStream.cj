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
import std.io.{InputStream, OutputStream, SeekPosition}
import fountain::f_util.{crc32Finish, crc32Init, crc32Update}

/**
 * 限长输入流：读到 `length` 字节后返回 -1，**不会**多读一个字节。
 *
 * 传入的 `buffer` 比剩余长度大时用临时数组截断，避免把下一条目的数据读进来。
 */
internal class BoundedInputStream <: InputStream {
    private let input: InputStream
    private var remaining: Int64

    public init(input: InputStream, length: Int64) {
        this.input = input
        this.remaining = length
    }

    public prop left: Int64 {
        get() {
            remaining
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (remaining <= 0 || buffer.size == 0) {
            return -1
        }
        if (buffer.size <= remaining) {
            let n = input.read(buffer)
            if (n <= 0) {
                remaining = 0
                return -1
            }
            remaining -= n
            return n
        }
        let tmp = Array<Byte>(remaining, repeat: 0)
        let n = input.read(tmp)
        if (n <= 0) {
            remaining = 0
            return -1
        }
        tmp[0..n].copyTo(buffer, 0, 0, n)
        remaining -= n
        n
    }
}

/** 内存字节数组上的限长流：不复制底层数组，游标独立。 */
internal class ArrayRangeInputStream <: InputStream {
    private let data: Array<Byte>
    private var position: Int64
    private let end: Int64

    public init(data: Array<Byte>, offset: Int64, length: Int64) {
        this.data = data
        this.position = offset
        let limit = offset + length
        this.end = if (limit > data.size) {
            data.size
        } else {
            limit
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (position >= end || buffer.size == 0) {
            return -1
        }
        let left = end - position
        let n = if (buffer.size < left) {
            buffer.size
        } else {
            left
        }
        data.copyTo(buffer, position, 0, n)
        position += n
        n
    }
}

/**
 * 文件上的限长流：每次 `openRange` 都**另开一个 File 句柄**，
 * 所以多个 `open` 并发读不会互相打乱光标。读完（或出错）时自动关句柄。
 */
internal class FileRangeInputStream <: InputStream {
    private var file: File
    private var remaining: Int64
    private var closed: Bool = false

    public init(path: String, offset: Int64, length: Int64) {
        this.file = File(path, OpenMode.Read)
        this.remaining = length
        if (offset > 0) {
            file.seek(Begin(offset))
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed || remaining <= 0 || buffer.size == 0) {
            closeQuietly()
            return -1
        }
        if (buffer.size <= remaining) {
            let n = file.read(buffer)
            if (n <= 0) {
                remaining = 0
                closeQuietly()
                return -1
            }
            remaining -= n
            return n
        }
        let tmp = Array<Byte>(remaining, repeat: 0)
        let n = file.read(tmp)
        if (n <= 0) {
            remaining = 0
            closeQuietly()
            return -1
        }
        tmp[0..n].copyTo(buffer, 0, 0, n)
        remaining -= n
        n
    }

    public func closeQuietly(): Unit {
        if (!closed) {
            closed = true
            try {
                file.close()
            } catch (_: Exception) {}
        }
    }
}

/** 最外层计数流：`position` 的唯一来源。 */
internal class CountingOutputStream <: OutputStream {
    private let out: OutputStream
    private var written: Int64 = 0

    public init(out: OutputStream) {
        this.out = out
    }

    public prop count: Int64 {
        get() {
            written
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        out.write(buffer)
        written += buffer.size
    }

    public func flush(): Unit {
        out.flush()
    }
}

/**
 * CRC 计数输入流：对**原始未压缩**字节算 CRC 并数原始字节数。
 *
 * 必须紧贴 `input`——顺序一旦变成"压缩后再算 CRC"，外部工具会报 CRC mismatch，
 * 而我们自己的 reader 因为同一套错误逻辑反而读得通。
 */
internal class Crc32InputStream <: InputStream {
    private let input: InputStream
    private var crc: UInt32 = crc32Init()
    private var readCount: Int64 = 0

    public init(input: InputStream) {
        this.input = input
    }

    public prop count: Int64 {
        get() {
            readCount
        }
    }

    public func checksum(): UInt32 {
        crc32Finish(crc)
    }

    public func read(buffer: Array<Byte>): Int64 {
        let n = input.read(buffer)
        if (n <= 0) {
            return -1
        }
        crc = crc32Update(crc, buffer[0..n])
        readCount += n
        n
    }
}

/**
 * 读一次并把底层解压器的异常统一成 `ZipException`：
 * 截断的 deflate 流会让 zlib 抛它自己的异常类型，直接冒出去会让调用方
 * 不得不同时 catch 两套异常。
 */
internal func safeRead(stream: InputStream, buf: Array<Byte>, entryName: String): Int64 {
    try {
        stream.read(buf)
    } catch (e: ZipException) {
        throw e
    } catch (e: Exception) {
        throw ZipException("条目 ${entryName} 数据不完整（解压失败：${e.message}）")
    }
}
