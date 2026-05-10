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

/**
 * 单个消息队列。
 * 封装 SegmentedLog（写）和文件读取（读）。
 * 消费直接从 SegmentedLog 流式读取，无内存缓冲，内存 O(1)。
 */
public class Queue <: Resource & ToString {
    let topic: String
    let index: Int64
    let log: SegmentedLog
    let retryBuffer: ArrayList<RetryEntry> = ArrayList()
    let deadLetter: DeadLetterStore
    var onServers: ArrayList<String> = ArrayList()
    private let logPath: String
    private var closed: Bool = false
    var draining: Bool = false
    private var logStream: ?InputStream = None  // SegmentedLog 流式游标

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
     */
    public func append(data: Array<Byte>): LogPosition {
        if (draining) { throw MqException("queue is draining") }
        if (closed) { throw MqException("queue is closed") }
        let buf = ByteBuffer()
        DefaultCodec().encode(data)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let framed = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(framed)
        log.append(framed)
    }

    public func sync(): Unit { log.sync() }

    /**
     * 从 SegmentedLog 流式读取下一条消息。
     * 使用游标逐条读取，不缓冲，内存 O(1)。
     */
    public func tryReadFromLog(): ?Array<Byte> {
        if (closed) { return None }
        try {
            let stream = if (let Some(s) <- logStream) { s } else {
                let s = log.openEntryStream()
                logStream = s
                s
            }
            let dec = DefaultCodec()
            if (let Some(entry) <- dec.decode<Array<Byte>>(stream)) {
                Some(entry)
            } else {
                if (let r: Resource <- stream) { r.close() }
                logStream = None
                None
            }
        } catch (_: Exception) { None }
    }

    public func close(): Unit {
        if (closed) { return }
        closed = true
        draining = false
        if (let Some(s) <- logStream) {
            if (let r: Resource <- s) { r.close() }
            logStream = None
        }
        log.close()
    }

    public func isClosed(): Bool { closed }

    public func tryFinishDrain(): Bool {
        if (!draining) { return true }
        if (logStream.isNone()) {
            close()
            return true
        }
        false
    }

    public func toString(): String { "Queue(${topic}[${index}])" }
}

public class RetryEntry {
    let logPosition: LogPosition
    let data: Array<Byte>
    var retryCount: Int64

    public init(logPosition: LogPosition, data: Array<Byte>, retryCount!: Int64 = 0) {
        this.logPosition = logPosition
        this.data = data
        this.retryCount = retryCount
    }
}
