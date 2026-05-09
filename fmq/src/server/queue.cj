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
import std.collection.concurrent.LinkedBlockingQueue

/**
 * 单个消息队列。
 * 封装 SegmentedLog（写）和文件读取（读）。
 */
public class Queue <: Resource & ToString {
    let topic: String
    let index: Int64
    let log: SegmentedLog
    let retryBuffer: ArrayList<RetryEntry> = ArrayList()
    let deadLetter: DeadLetterStore
    let deliveryBuffer: LinkedBlockingQueue<Array<Byte>>  // Writer → Reader 管道
    private let logPath: String
    private var closed: Bool = false

    public init(topic: String, index: Int64, dataDir: String, segmentSize: Int64) {
        this.topic = topic
        this.index = index
        let encodedTopic = encodeTopicToPath(topic)
        this.logPath = "${dataDir}/${encodedTopic}/${index}"
        let config = LogConfig(
            this.logPath,
            "mq_${encodedTopic}_${index}",
            segmentSize,
            100,      // syncInterval = 100 appends
            fileExt: ".log"
        )
        this.log = SegmentedLog(config)
        this.deadLetter = DeadLetterStore(this.logPath)
        this.deliveryBuffer = LinkedBlockingQueue<Array<Byte>>(1024)
    }

    /**
     * 追加消息到队列。
     * 返回写入位置，用于追踪 offset。
     */
    public func append(data: Array<Byte>): LogPosition {
        if (closed) { throw MqException("queue is closed") }
        log.append(data)
    }

    public func sync(): Unit { log.sync() }

    public func close(): Unit {
        if (closed) { return }
        closed = true
        log.close()
    }

    public func isClosed(): Bool { closed }

    public func toString(): String { "Queue(${topic}[${index}])" }
}

/**
 * 重试条目。
 */
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
