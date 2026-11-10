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

import std.io.OutputStream
import stdx.compress.zlib.{CompressOutputStream, WrapType}
import fountain::f_util.{crc32Init, crc32Update, crc32Finish}

/**
 * 推模式条目输出流：调用方直接 `write()`，关闭时写 24 字节 data descriptor 并登记条目。
 *
 * 与 `addFileStream` 共用同一条流式路径（local header 真实值留空 + bit 3 + ZIP64 占位），
 * 区别只在数据由调用方推入，不需要先造 `InputStream` 适配器。
 *
 * 条目流关闭后**不得**再写；重复 `close()` 幂等。写入失败会把 `ZipWriter` 置为脏状态
 * （半截 local header 无法修补），此后 writer 的任何操作都抛异常。
 */
public class ZipEntryOutputStream <: OutputStream {
    private let writer: ZipWriter
    private let counter: CountingOutputStream
    private let compressor: ?CompressOutputStream
    private let name: String
    private let nameBytes: Array<Byte>
    private let utf8: Bool
    private let method: UInt16
    private let dosTime: UInt16
    private let dosDate: UInt16
    private let offset: Int64
    private var crc: UInt32 = crc32Init()
    private var uncompressed: Int64 = 0
    private var closed = false
    private var failed = false

    internal init(
        writer: ZipWriter,
        out: CountingOutputStream,
        name: String,
        nameBytes: Array<Byte>,
        utf8: Bool,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        offset: Int64
    ) {
        this.writer = writer
        this.counter = CountingOutputStream(out)
        this.compressor = if (method == 8) {
            Some(CompressOutputStream(this.counter, wrap: WrapType.DeflateFormat, bufLen: 8192))
        } else {
            None<CompressOutputStream>
        }
        this.name = name
        this.nameBytes = nameBytes
        this.utf8 = utf8
        this.method = method
        this.dosTime = dosTime
        this.dosDate = dosDate
        this.offset = offset
    }

    /** 实际写入的条目名（同名冲突时会被改名）。 */
    public prop entryName: String {
        get() {
            name
        }
    }

    /** 已写入的未压缩字节数。 */
    public prop count: Int64 {
        get() {
            uncompressed
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        if (closed) {
            throw ZipException("条目 ${name} 已关闭，不能继续写入")
        }
        if (failed) {
            return
        }
        if (buffer.size == 0) {
            return
        }
        try {
            crc = crc32Update(crc, buffer)
            uncompressed += buffer.size
            match (compressor) {
                case Some(c) => c.write(buffer)
                case None => counter.write(buffer)
            }
        } catch (e: Exception) {
            failed = true
            writer.entryFailed(name)
            throw e
        }
    }

    /** 只把压缩器内部缓冲推到条目数据区，不结束条目。 */
    public func flush(): Unit {
        if (closed || failed) {
            return
        }
        match (compressor) {
            case Some(c) => c.flush()
            case None => ()
        }
    }

    /**
     * 结束条目：关闭压缩器 → 写 data descriptor → 登记中央目录信息。
     * 幂等；失败后 writer 进入脏状态。
     */
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        if (failed) {
            return
        }
        try {
            match (compressor) {
                case Some(c) => c.close()
                case None => ()
            }
            let compressedSize = counter.count
            let finalCrc = crc32Finish(crc)
            writer.finishEntry(
                name,
                nameBytes,
                utf8,
                method,
                dosTime,
                dosDate,
                finalCrc,
                compressedSize,
                uncompressed,
                offset
            )
        } catch (e: Exception) {
            failed = true
            writer.entryFailed(name)
            throw e
        }
    }
}
