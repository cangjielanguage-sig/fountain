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

import std.io.InputStream
import std.time.DateTime
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.convert
import fountain::f_io.{LogPosition, SegmentedLog, LogConfig}
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.MQDeadLetterMessage

/**
 * 死信队列：独立 `SegmentedLog`，每条为自描述的 `codec(MQDeadLetterMessage)`。
 *
 * 目录：`<deadMsgDir>/log_<seq>.log`。
 */
protected class DeadLetterQueue <: Resource {
    private let log: SegmentedLog

    protected init(dir: String, maxFileSize: Int64, syncInterval: Int64) {
        this.log = SegmentedLog(LogConfig(dir, "log", maxFileSize, syncInterval))
    }

    protected func append(message: MQDeadLetterMessage): LogPosition {
        log.append(MQProtocol.encodePayload<MQDeadLetterMessage>(message))
    }

    /** 从指定位置顺序读取；专门的死信消费者用它。 */
    protected func iterate(from: LogPosition): Iterator<MQDeadLetterMessage> {
        DeadLetterReader(log.openEntryStream(from.seq, from.offset))
    }

    /** 删除 `updateTime + ttl < now` 的封口段，返回删除段数；当前段永不删除。 */
    protected func cleanExpired(ttl: Duration, now: DateTime): Int64 {
        var removed = 0i64
        for (meta in log.logMetas()) {
            if (meta.last) {
                continue
            }
            if (meta.updateTime + ttl < now) {
                log.removeById(meta.index)
                removed++
            }
        }
        removed
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
}

/** 逐条解码死信条目；流尽或遇到损坏时结束。 */
protected class DeadLetterReader <: Iterator<MQDeadLetterMessage> {
    private let stream: InputStream
    private var finished = false

    init(stream: InputStream) {
        this.stream = stream
    }

    public func next(): ?MQDeadLetterMessage {
        if (finished) {
            return None<MQDeadLetterMessage>
        }
        let codec = DefaultCodec()
        var result: ?MQDeadLetterMessage = None
        try {
            result = convert<MQDeadLetterMessage>(codec.decodeData(stream))
        } catch (_: Exception) {
            finished = true
            if (let r: Resource <- stream) {
                if (!r.isClosed()) {
                    r.close()
                }
            }
        } finally {
            codec.release()
        }
        result
    }
}
