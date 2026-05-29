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
package fountain::fmq.server

import fountain::f_io.{SegmentedLog, LogConfig, LogPosition}
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import std.sync.{Mutex, AtomicBool}

/**
 * 单个消息队列。
 * 封装 SegmentedLog（写）和文件读取（读）。
 * 消费直接从 SegmentedLog 流式读取，无内存缓冲，内存 O(1)。
 */
public class MqQueue <: Resource & ToString {
    let topic: String
    let index: Int64
    let log: SegmentedLog
    let deadLetter: DeadLetterStore
    private let logPath: String
    private let closed = AtomicBool(false)
    var draining = AtomicBool(false)
    private var logStream: ?InputStream = None  // SegmentedLog 流式游标
    private let streamLock = Mutex()  // 保护 logStream 延迟初始化和关闭、log.close()

    public init(topic: String, index: Int64, dataDir: String, segmentSize: Int64) {
        this.topic = topic
        this.index = index
        let encodedTopic = encodeTopicToPath(topic)
        this.logPath = "${dataDir}/${encodedTopic}/${index}"
        let config = LogConfig(
            this.logPath,
            "mq_${encodedTopic}_${index}",
            segmentSize,
            100,
            fileExt: ".log"
        )
        this.log = SegmentedLog(config)
        this.deadLetter = DeadLetterStore(this.logPath)
    }

    /**
     * 追加消息到队列。排空中拒绝追加。
     * 用 DefaultCodec 编码写入 SegmentedLog，确保帧边界。
     * @return LogPosition 写入位置（当前调用方均丢弃此值，保留用于未来精确 offset 跟踪）
     */
    public func append(data: Array<Byte>): LogPosition {
        if (draining.load()) { throw MqException("queue is draining") }
        if (closed.load()) { throw MqException("queue is closed") }
        let buf = ByteBuffer()
        DefaultCodec().encode(data)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let framed = extractBytes(buf)
        log.append(framed)
    }

    public func sync(): Unit { log.sync() }

    /**
     * 从 SegmentedLog 流式读取下一条消息。
     * @param skip 跳过的已消费消息数（offset），首次读取时用于跳过历史消息
     */
    public func tryReadFromLog(skip: Int64): ?Array<Byte> {
        synchronized(streamLock) {
            if (closed.load()) { return None }
            try {
                let dec = DefaultCodec()
                if (let Some(s) <- logStream) {
                    if (let Some(entry) <- dec.decode<Array<Byte>>(s)) {
                        Some(entry)
                    } else {
                        if (let r: Resource <- s) { r.close() }
                        logStream = None
                        None
                    }
                } else {
                    let s = log.openEntryStream()
                    var remaining = skip
                    while (remaining > 0) {
                        if (dec.decode<Array<Byte>>(s).isNone()) { break }
                        remaining -= 1
                    }
                    if (let Some(entry) <- dec.decode<Array<Byte>>(s)) {
                        logStream = s
                        Some(entry)
                    } else {
                        if (let r: Resource <- s) { r.close() }
                        None
                    }
                }
            } catch (_: Exception) {
                if (let Some(s) <- logStream) {
                    if (let r: Resource <- s) { r.close() }
                    logStream = None
                }
                None
            }
        }
    }

    public func close(): Unit {
        if (closed.load()) { return }
        synchronized(streamLock) {
            if (closed.load()) { return }
            closed.store(true)
            // 不在 close() 中重置 draining——closed=true 已足够阻止所有操作。
            // 若 close 由 tryFinishDrain() 触发，draining 状态应保持供外部检查。
            // 在锁内关闭 logStream，阻止 reader 线程继续使用流
            if (let Some(s) <- logStream) {
                if (let r: Resource <- s) { r.close() }
                logStream = None
            }
        }
        // 锁外关闭底层 SegmentedLog。此时所有 reader 线程已看到 closed=true 并退出，
        // 或尚未进入同步块而在进入后立即检测到 closed。
        log.close()
        deadLetter.close()
    }

    public func isClosed(): Bool { closed.load() }

    /**
     * 检查排空是否完成。排空模式下，若 logStream 已耗尽则关闭队列。
     * ⚠️ 已知限制：SegmentedLog 的 openEntryStream() 在空日志上行为不确定，
     * 因此不在 tryFinishDrain 中尝试重新打开流检查残留数据。
     * 排空期间如有新数据追加到 SegmentedLog，日志将在下次 consume 周期
     * 通过 tryReadFromLog 重新打开流时被读取。
     */
    public func tryFinishDrain(): Bool {
        if (!draining.load()) { return true }
        let streamAlive: Bool
        synchronized(streamLock) {
            streamAlive = logStream.isSome()
        }
        if (!streamAlive) {
            close()
            return true
        }
        false
    }

    public func toString(): String { "MqQueue(${topic}[${index}])" }
}
