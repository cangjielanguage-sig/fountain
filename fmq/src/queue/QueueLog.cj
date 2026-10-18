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
package fountain::fmq.queue

import std.collection.ArrayList
import std.io.InputStream
import fountain::f_io.*

/**
 * 一条队列 = 一个 `SegmentedLog`。
 *
 * 每条记录在段内以 `[4B 大端长度][记录字节]` 存放：记录本身仍是 `MQMessageRecord` 的原始
 * 字节串（原样落盘），4 字节头只用来在按位置顺序读取时确定单条边界 —— 它不是索引文件，
 * 也不引入第二份写盘。
 */
protected class QueueLog <: Resource {
    static let PREFIX_SIZE: Int64 = 4
    private static let MAX_RECORD_SIZE: Int64 = 64 * 1024 * 1024

    private let log: SegmentedLog

    protected init(dir: String, maxFileSize: Int64, syncInterval: Int64) {
        this.log = SegmentedLog(LogConfig(dir, "log", maxFileSize, syncInterval))
    }

    protected func append(record: Array<Byte>): LogPosition {
        if (record.size > MAX_RECORD_SIZE) {
            throw IllegalArgumentException("record too large: ${record.size} bytes, limit ${MAX_RECORD_SIZE}")
        }
        let entry = Array<Byte>(PREFIX_SIZE + record.size, repeat: 0u8)
        QueueLog.putInt32BE(entry, 0, record.size)
        record.copyTo(entry, 0, PREFIX_SIZE, record.size)
        log.append(entry)
    }

    /** 从位置起读一条记录；位置无效或记录损坏返回 `None`。 */
    protected func readAt(position: LogPosition): ?Array<Byte> {
        let reader = openRecordsFrom(position)
        try {
            match (reader.next()) {
                case Some(item) => Some(item[0])
                case None => None<Array<Byte>>
            }
        } finally {
            reader.close()
        }
    }

    /** 从位置起打开原始顺序流（快照语义：之后新 append 的数据不出现）。 */
    protected func openFrom(position: LogPosition): InputStream {
        log.openEntryStream(position.seq, position.offset)
    }

    /** 从位置起按记录边界顺序读取（游标用）。 */
    protected func openRecordsFrom(position: LogPosition): QueueRecordReader {
        QueueRecordReader(openFrom(position), segments(), position)
    }

    /** 删除指定段（当前段由 f_io 拒绝）。 */
    protected func removeById(index: Int64): Unit {
        log.removeById(index)
    }

    protected func segments(): ArrayList<SegmentedMeta> {
        log.logMetas()
    }

    /** 有效字节数（各段有效长度之和，含 4 字节头）。 */
    protected prop size: Int64 {
        get() {
            var total = 0i64
            for (meta in log.logMetas()) {
                total += meta.size
            }
            total
        }
    }

    protected func sync(): Unit {
        log.sync()
    }

    public func isClosed(): Bool {
        log.isClosed()
    }

    public func close(): Unit {
        log.close()
    }

    private static func putInt32BE(out: Array<Byte>, offset: Int64, value: Int64): Unit {
        out[offset] = UInt8((value >> 24) & 0xff)
        out[offset + 1] = UInt8((value >> 16) & 0xff)
        out[offset + 2] = UInt8((value >> 8) & 0xff)
        out[offset + 3] = UInt8(value & 0xff)
    }

    static func getInt32BE(data: Array<Byte>, offset: Int64): Int64 {
        (Int64(data[offset]) << 24) | (Int64(data[offset + 1]) << 16) |
            (Int64(data[offset + 2]) << 8) | Int64(data[offset + 3])
    }
}

/**
 * 按 `[长度][记录]` 的边界从段流中逐条读出记录，并维护每条记录的 `LogPosition`。
 *
 * 段边界来自创建时的 `logMetas()` 快照，与段流的有界快照一致；记录不会跨段。
 */
protected class QueueRecordReader {
    private let stream: InputStream
    private let segments: ArrayList<SegmentedMeta>
    private var seq: Int64
    private var offset: Int64
    private var closed = false

    init(stream: InputStream, segments: ArrayList<SegmentedMeta>, start: LogPosition) {
        this.stream = stream
        this.segments = segments
        this.seq = start.seq
        this.offset = start.offset
    }

    protected func next(): ?(Array<Byte>, LogPosition) {
        if (closed) {
            return None<(Array<Byte>, LogPosition)>
        }
        let header = readExact(QueueLog.PREFIX_SIZE)
        match (header) {
            case None =>
                close()
                None<(Array<Byte>, LogPosition)>
            case Some(h) =>
                let length = QueueLog.getInt32BE(h, 0)
                if (length <= 0) {
                    close()
                    None<(Array<Byte>, LogPosition)>
                }
                let body = readExact(length)
                match (body) {
                    case None =>
                        close()
                        None<(Array<Byte>, LogPosition)>
                    case Some(record) =>
                        let position = LogPosition(seq, offset)
                        advance(QueueLog.PREFIX_SIZE + length)
                        Some((record, position))
                }
        }
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        if (let r: Resource <- stream) {
            if (!r.isClosed()) {
                r.close()
            }
        }
    }

    protected func isClosed(): Bool {
        closed
    }

    /** 下一条记录的起始位置（读完当前记录后调用）。 */
    protected func position(): LogPosition {
        LogPosition(seq, offset)
    }

    /** 读满 `size` 字节；流在一开始就结束返回 `None`，读到一半结束视为记录损坏。 */
    private func readExact(size: Int64): ?Array<Byte> {
        let out = Array<Byte>(size, repeat: 0u8)
        var got = 0i64
        while (got < size) {
            let tmp = Array<Byte>(size - got, repeat: 0u8)
            let n = stream.read(tmp)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out[got + i] = tmp[i]
            }
            got += n
        }
        if (got == 0) {
            None<Array<Byte>>
        } else if (got < size) {
            throw IllegalArgumentException("truncated queue record: need ${size} bytes, got ${got}")
        } else {
            Some(out)
        }
    }

    /** 按段长度把 consumed 字节映射到新的 (segment, offset)。 */
    private func advance(consumed: Int64): Unit {
        var index = segmentIndex(seq)
        if (index < 0) {
            offset += consumed
            return
        }
        var remaining = offset + consumed
        while (index < segments.size && remaining > segments[index].size) {
            remaining -= segments[index].size
            index++
        }
        if (index >= segments.size) {
            // 已越过快照末尾：保持在末尾，后续读会立即 EOF
            seq = segments[segments.size - 1].index
            offset = segments[segments.size - 1].size
            return
        }
        if (remaining == segments[index].size && index + 1 < segments.size) {
            seq = segments[index + 1].index
            offset = 0
        } else {
            seq = segments[index].index
            offset = remaining
        }
    }

    private func segmentIndex(target: Int64): Int64 {
        for (i in 0..segments.size) {
            if (segments[i].index == target) {
                return i
            }
        }
        -1
    }
}
