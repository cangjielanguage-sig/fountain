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
package fountain::f_mcp

import std.collection.ArrayList
import std.io.InputStream
import std.time.MonoTime

/**
 * `/mcp/sse` 的流：把订阅者队列里的 JSON-RPC 通知写成 `text/event-stream`。
 *
 * - 没有事件时每 100ms 轮询一次；15 秒没有事件发一条注释行保活
 * - 最长存活 30 分钟，之后返回 EOF（客户端会自动重连）
 * - `close()` 注销订阅
 */
public class McpSseStream <: InputStream {
    private let hub: SubscriptionHub
    private let subscriber: McpSubscriber
    private var pending = Array<Byte>()
    private var pendingOffset = 0
    private var closed = false
    private let startedNanos = MonoTime.now()
    private var lastWriteNanos = MonoTime.now()

    public init(hub: SubscriptionHub, topics: ArrayList<String>) {
        this.hub = hub
        this.subscriber = hub.subscribe(topics)
    }

    /** 绑定 `subscriptions/listen` 已经创建的订阅者。 */
    public init(hub: SubscriptionHub, subscriber: McpSubscriber) {
        this.hub = hub
        this.subscriber = subscriber
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed) {
            return -1
        }
        while (!closed && pendingOffset >= pending.size) {
            pending = nextChunk()
            pendingOffset = 0
        }
        if (closed && pendingOffset >= pending.size) {
            return -1
        }
        let available = pending.size - pendingOffset
        let count = min(Int64(buffer.size), available)
        for (i in 0..count) {
            buffer[i] = pending[pendingOffset + i]
        }
        pendingOffset += count
        count
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            hub.unsubscribe(subscriber)
        }
    }

    /** 测试用：直接取下一段字节（不阻塞）。 */
    public func poll(): ?Array<Byte> {
        if (closed) {
            return None<Array<Byte>>
        }
        let chunk = nextChunk()
        if (chunk.size == 0) {
            None<Array<Byte>>
        } else {
            Some(chunk)
        }
    }

    private func nextChunk(): Array<Byte> {
        if ((MonoTime.now() - startedNanos) > Duration.minute * 30) {
            closed = true
            hub.unsubscribe(subscriber)
            return Array<Byte>()
        }
        let events = subscriber.drain()
        if (!events.isEmpty()) {
            var text = ''
            for (event in events) {
                text += 'event: message\n'
                text += 'data: ${event.toString()}\n\n'
            }
            lastWriteNanos = MonoTime.now()
            return text.toArray()
        }
        if ((MonoTime.now() - lastWriteNanos) > Duration.second * 15) {
            lastWriteNanos = MonoTime.now()
            return ': ping\n\n'.toArray()
        }
        sleep(Duration.millisecond * 100)
        Array<Byte>()
    }
}
