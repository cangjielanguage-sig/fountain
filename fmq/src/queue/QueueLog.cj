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
import std.time.DateTime
import fountain::f_io.*
import fountain::f_log.*
import fountain::f_mq.base.MQMessageRecord

/**
 * 段消失后的恢复结论。
 *
 * `StillPresent` 表示目标段仍在（异常另有原因，调用方应继续抛出）；
 * `Moved` 表示已把游标移到后继段起点；`NoFuture` 表示已无任何可读段，应按空队列处理。
 */
protected enum SegmentRecovery {
    | StillPresent
    | Moved
    | NoFuture
}

/**
 * 一条队列 = 一个 `SegmentedLog`。
 *
 * 每条记录在段内以 `[4B 大端长度][记录字节]` 存放：记录本身仍是 `MQMessageRecord` 的原始
 * 字节串（原样落盘），4 字节头只用来在按位置顺序读取时确定单条边界 —— 它不是索引文件，
 * 也不引入第二份写盘。
 */
protected class QueueLog <: Resource {
    static let logger = LoggerFactory.getLogger("fountain::fmq.queue.QueueLog")
    static let PREFIX_SIZE: Int64 = 4
    /** 单条记录上界；读端必须在分配缓冲前用它挡掉损坏的长度头。 */
    static let MAX_RECORD_SIZE: Int64 = 64 * 1024 * 1024

    private let log: SegmentedLog
    private let label: String
    /** 段缺失/越界 WARN 的秒级限流（R3-M9）。 */
    private let warnLimiter: WarnLimiter
    /** 单条记录的真实上限：段容量减长度头，再与 `MAX_RECORD_SIZE` 取小。 */
    private let effectiveMaxRecord: Int64

    protected init(dir: String, maxFileSize: Int64, syncInterval: Int64,
        warnNowMs!: () -> Int64 = {=> DateTime.now().toUnixTimeStamp().toMilliseconds()}) {
        if (maxFileSize <= PREFIX_SIZE) {
            throw IllegalArgumentException(
                "segment size ${maxFileSize} must be greater than the ${PREFIX_SIZE}-byte record header")
        }
        this.log = SegmentedLog(LogConfig(dir, "log", maxFileSize, syncInterval))
        this.label = dir
        this.warnLimiter = WarnLimiter(nowMs: warnNowMs)
        let bySegment = maxFileSize - PREFIX_SIZE
        this.effectiveMaxRecord = if (bySegment < MAX_RECORD_SIZE) {
            bySegment
        } else {
            MAX_RECORD_SIZE
        }
    }

    protected func append(record: Array<Byte>): LogPosition {
        if (record.size == 0) {
            throw IllegalArgumentException("empty record is not allowed")
        }
        if (record.size > effectiveMaxRecord) {
            throw IllegalArgumentException(
                "record too large: ${record.size} bytes, limit ${effectiveMaxRecord}")
        }
        let entry = Array<Byte>(PREFIX_SIZE + record.size, repeat: 0u8)
        QueueLog.putInt32BE(entry, 0, record.size)
        record.copyTo(entry, 0, PREFIX_SIZE, record.size)
        log.append(entry)
    }

    /**
     * 从位置起读一条记录，并区分「读到了」「记录损坏」「段已不存在」。
     *
     * 调用方必须能分开处理损坏与段缺失：损坏时不推进游标（否则丢消息），
     * 段缺失时按恢复语义前移（R3-M1/M2）。
     */
    protected func readAt(position: LogPosition): LogReadResult {
        let reader = openRecordsFrom(position)
        try {
            match (reader.next()) {
                case Some(item) => LogReadResult.Record(item[0])
                case None =>
                    if (reader.isCorrupted()) {
                        LogReadResult.Corrupt
                    } else {
                        LogReadResult.SegmentGone
                    }
            }
        } finally {
            reader.close()
        }
    }

    /** 从位置起打开原始顺序流（快照语义：之后新 append 的数据不出现）。 */
    protected func openFrom(position: LogPosition): InputStream {
        let segs = segmentsOrEmpty()
        match (startPositionOf(segs, position)) {
            case Some(start) => log.openEntryStream(start.seq, start.offset)
            // 没有任何可读段：按空流处理，调用方读到 EOF，不抛异常（A47）
            case None => ByteBuffer()
        }
    }

    /** 从位置起按记录边界顺序读取（游标用）。 */
    protected func openRecordsFrom(position: LogPosition): QueueRecordReader {
        let segs = segmentsOrEmpty()
        match (startPositionOf(segs, position)) {
            case Some(start) => QueueRecordReader(log.openEntryStream(start.seq, start.offset), segs, start, label)
            case None => QueueRecordReader(ByteBuffer(), segs, position, label)
        }
    }

    /**
     * 起点归一化：把外部持久化位点映射到「确实还有字节可读」的起点。
     *
     * - 段存在且 `offset < size`：原样返回；
     * - 段存在但已读满（`offset >= size`）：落到**编号更大的最近现存段**起点，`offset > size` 记 WARN
     *   （游标异常），`offset == size` 只是正常的段末尾；
     * - 段已被清理：同样跳到更大段并 WARN；没有后继段返回 `None`（调用方按空流处理）。
     */
    /**
     * 解析「从该位点开始还能读到的起点」。
     *
     * `strict = true` 表示调用方不接受任何恢复：位点所在段不存在时直接抛
     * [QueueCorruptionException]（`stats` 用它区分「还没被消费路径修复」与「真的读完了」）。
     */
    protected func resolveStart(position: LogPosition, strict!: Bool = false): ?LogPosition {
        let segments = segmentsOrEmpty()
        for (meta in segments) {
            if (meta.index == position.seq) {
                return startPositionOf(segments, position)
            }
        }
        if (strict) {
            throw QueueCorruptionException(
                "segment ${position.seq} of queue ${label} is missing (position ${position.seq}:${position.offset})")
        }
        return startPositionOf(segments, position)
    }

    private func startPositionOf(segments: ArrayList<SegmentedMeta>, position: LogPosition): ?LogPosition {
        for (meta in segments) {
            if (meta.index != position.seq) {
                continue
            }
            if (position.offset < meta.size) {
                return Some(position)
            }
            if (position.offset > meta.size && warnLimiter.allow("past-end\u{0}${position.seq}:${position.offset}")) {
                logger.warn("position ${position.seq}:${position.offset} of queue ${label} is past segment end " +
                    "${meta.size}: continuing at the next segment")
            }
            return startAfter(segments, position.seq)
        }
        if (warnLimiter.allow("missing\u{0}${position.seq}:${position.offset}")) {
            logger.warn("stream of queue ${label} starts at the next existing segment instead of " +
                "${position.seq}:${position.offset} because that segment was removed")
        }
        startAfter(segments, position.seq)
    }

    /** `seq` 之后（不含 `seq`）的最近现存段起点。 */
    private func startAfter(segments: ArrayList<SegmentedMeta>, seq: Int64): ?LogPosition {
        match (QueueLog.startSegmentAtOrAfter(segments, seq + 1)) {
            case Some(index) => Some(LogPosition(index, 0))
            case None =>
                if (warnLimiter.allow("no-successor\u{0}${seq}")) {
                    logger.warn("no segment after ${seq} on queue ${label}, treated as empty stream")
                }
                None<LogPosition>
        }
    }

    /** 删除指定段（当前段由 f_io 拒绝）。 */
    protected func removeById(index: Int64): Unit {
        log.removeById(index)
    }

    protected func segments(): ArrayList<SegmentedMeta> {
        log.logMetas()
    }

    /** 段元数据；目录不可读（例如整个队列目录被删除）时返回空，调用方按「无段可读」处理。 */
    protected func segmentsOrEmpty(): ArrayList<SegmentedMeta> {
        try {
            segments()
        } catch (_: Exception) {
            ArrayList<SegmentedMeta>()
        }
    }

    /**
     * 从 `position` 起扫描记录：返回记录数与第一条记录的发布时间。
     *
     * 用于统计：`backlog` 与 `lagMs` 不依赖内存计数器，重启后仍然准确。
     * 起始段被 TTL 清理时跳到「最接近的更大段」继续并记 WARN；没有任何后继段（或目录不可读）
     * 返回 `(0, None)` 并记 WARN，不把「段缺失」静默解释成「没有积压」。
     */
    protected func scanAfter(position: LogPosition): (Int64, ?DateTime) {
        let segs = segmentsOrEmpty()
        if (segs.size == 0) {
            logger.warn("no segment left on queue ${label}, treated as empty")
            return (0, None<DateTime>)
        }
        // 起点段被清理的恢复与 WARN 由 openRecordsFrom 统一负责
        scanFrom(position)
    }

    /** 从现存段中 `index >= position.seq` 的最小段号起扫描。 */
    private func scanFrom(start: LogPosition): (Int64, ?DateTime) {
        var count = 0i64
        var first: ?DateTime = None
        var firstResolved = false
        try {
            let reader = openRecordsFrom(start)
            try {
                while (true) {
                    match (reader.next()) {
                        case Some(item) =>
                            count++
                            if (!firstResolved) {
                                // 只看第一条：它无法解析时 lag 未知，固定为 None（调用方输出 0）
                                first = MQMessageRecord.publishTime(item[0])
                                firstResolved = true
                            }
                        case None => break
                    }
                }
                if (reader.isCorrupted()) {
                    throw QueueCorruptionException("queue ${label} is corrupted at ${start.seq}:${start.offset}")
                }
            } finally {
                reader.close()
            }
        } catch (e: QueueCorruptionException) {
            // 损坏必须让调用方看见（stats 转 ERROR、consume 转空 + WARN），不能吞成「0 条」
            throw e
        } catch (_: Exception) {
            return (0, None<DateTime>)
        }
        (count, first)
    }

    /** 当前队列的记录总数（从现存最老段扫描）。 */
    protected func countAll(): Int64 {
        let segs = segmentsOrEmpty()
        if (segs.size == 0) {
            return 0
        }
        scanFrom(LogPosition(segs[0].index, 0))[0]
    }

    /** 现存段中段号 `>= index` 的最小段号；没有则 `None`（段被删或全部缺失）。 */
    static func startSegmentAtOrAfter(segments: ArrayList<SegmentedMeta>, index: Int64): ?Int64 {
        for (meta in segments) {
            if (meta.index >= index) {
                return Some(meta.index)
            }
        }
        None<Int64>
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

/** 单条记录读取的三种结局：正常/损坏/段已不存在（R3-M1/M2）。 */
protected enum LogReadResult {
    | Record(Array<Byte>)
    | Corrupt
    | SegmentGone
}

/**
 * 按 `[长度][记录]` 的边界从段流中逐条读出记录，并维护每条记录的 `LogPosition`。
 *
 * 段边界来自创建时的 `logMetas()` 快照，与段流的有界快照一致；记录不会跨段。
 */
protected class QueueRecordReader {
    private let stream: InputStream
    private let segments: ArrayList<SegmentedMeta>
    private let label: String
    private var seq: Int64
    private var offset: Int64
    private var closed = false
    private var corrupted = false

    init(stream: InputStream, segments: ArrayList<SegmentedMeta>, start: LogPosition, label: String) {
        this.stream = stream
        this.segments = segments
        this.seq = start.seq
        this.offset = start.offset
        this.label = label
    }

    /** 是否因为记录损坏而提前结束（调用方据此区分「读完了」与「读坏了」）。 */
    protected func isCorrupted(): Bool {
        corrupted
    }

    protected func next(): ?(Array<Byte>, LogPosition) {
        if (closed || corrupted) {
            return None<(Array<Byte>, LogPosition)>
        }
        let header = readUpTo(QueueLog.PREFIX_SIZE)
        if (header.size == 0) {
            // 干净结束：本段已读完
            close()
            return None<(Array<Byte>, LogPosition)>
        }
        if (header.size < QueueLog.PREFIX_SIZE) {
            // 4 字节头不完整：截断的尾部
            return corrupt(0, -1, "incomplete record header (${header.size} bytes)")
        }
        let length = QueueLog.getInt32BE(header, 0)
        if (length == 0) {
            // 写入侧从不产生零长度条目：出现即说明记录损坏，必须停下而不是当成干净结束（R3-M1）
            return corrupt(0, -1, "zero-length record header")
        }
        match (segmentOf(seq)) {
            case None =>
                if (seq > lastSegmentIndex()) {
                    close()
                    return None<(Array<Byte>, LogPosition)>
                }
                return corrupt(length, -1, "segment ${seq} is missing")
            case Some(meta) =>
                // 只在通过上界与剩余字节校验后才分配缓冲
                let remaining = meta.size - offset - QueueLog.PREFIX_SIZE
                if (remaining < 0) {
                    // 起点归一化后不应出现：出现即说明调用方绕过了 startPositionOf 或位置被写坏
                    return corrupt(length, remaining,
                        "invariant broken: offset ${offset} is past segment ${seq} size ${meta.size}")
                }
                if (length < 0 || length > QueueLog.MAX_RECORD_SIZE) {
                    return corrupt(length, remaining,
                        "declared length ${length} exceeds limit ${QueueLog.MAX_RECORD_SIZE}")
                }
                if (length > remaining) {
                    return corrupt(length, remaining, "declared length ${length} exceeds remaining ${remaining}")
                }
                let body = readUpTo(length)
                if (body.size != length) {
                    return corrupt(length, remaining,
                        "declared length ${length} but read ${body.size}")
                }
                let position = LogPosition(seq, offset)
                advance(QueueLog.PREFIX_SIZE + length)
                return Some((body, position))
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

    /** 损坏：记 ERROR、关闭流、标记已损坏，返回 `None`。 */
    private func corrupt(declaredLength: Int64, remaining: Int64, reason: String): ?(Array<Byte>, LogPosition) {
        corrupted = true
        QueueLog.logger.error("corrupted queue record in ${label}: segment=${seq} offset=${offset} " +
            "declaredLength=${declaredLength} remaining=${remaining}: ${reason}")
        close()
        None<(Array<Byte>, LogPosition)>
    }

    /** 读最多 `size` 字节；返回实际读到的字节数（0 表示流结束）。 */
    private func readUpTo(size: Int64): Array<Byte> {
        if (size <= 0) {
            return Array<Byte>()
        }
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
        if (got == size) {
            out
        } else {
            out[0..got]
        }
    }

    private func segmentOf(index: Int64): ?SegmentedMeta {
        for (i in 0..segments.size) {
            if (segments[i].index == index) {
                return Some(segments[i])
            }
        }
        None<SegmentedMeta>
    }

    private func lastSegmentIndex(): Int64 {
        if (segments.size == 0) {
            return -1
        }
        segments[segments.size - 1].index
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
