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
package fountain::f_mcp.server

import std.collection.ArrayList
import std.io.InputStream
import std.time.MonoTime
import fountain::f_data.*

/**
 * `/mcp/sse` 的流：把订阅者队列里的 JSON-RPC 通知写成 `text/event-stream`。
 *
 * - 没有事件时阻塞等待 15 秒（`Condition.wait`），不再每 100ms 空转
 * - 15 秒没有事件发一条注释行保活
 * - 最长存活 30 分钟，之后 detach 并返回 EOF（客户端可用同一 id 重连）
 */
public class McpSseStream <: InputStream {
    private let hub: SubscriptionHub
    private let subscriber: McpSubscriber
    private var pending = Array<Byte>()
    private var pendingOffset = 0
    private var closed = false
    private let startedNanos = MonoTime.now()
    private var lastWriteNanos = MonoTime.now()

    /**
     * 直连路径：`/mcp/sse` 未带 `subscriptionId` 时自己建订阅者。
     *
     * 创建后立即 attach——不 attach 的订阅者既无法 `detach`，也无法在 TTL 后被回收。
     */
    public init(hub: SubscriptionHub, topics: ArrayList<String>) {
        this.hub = hub
        this.subscriber = hub.subscribeAttached(topics)
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
        // 一次性批量拷贝，不再逐字节赋值
        buffer[0..count] = pending[pendingOffset..pendingOffset + count]
        pendingOffset += count
        count
    }

    /** 该流对应的订阅者 id（测试与诊断用）。 */
    prop subscriberId: Int64 {
        get() {
            subscriber.id
        }
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            hub.detach(subscriber)
        }
    }

    /** 测试用：取走当前已入队的字节（不阻塞）。 */
    public func poll(): ?Array<Byte> {
        if (closed) {
            return None<Array<Byte>>
        }
        let events = subscriber.drain()
        if (events.isEmpty()) {
            None<Array<Byte>>
        } else {
            Some(render(events))
        }
    }

    private func nextChunk(): Array<Byte> {
        if ((MonoTime.now() - startedNanos) > Duration.minute * 30) {
            closed = true
            hub.detach(subscriber)
            return Array<Byte>()
        }
        // 带超时阻塞：有事件立即返回，没有就等满 15 秒
        let events = subscriber.take(Duration.second * 15)
        if (!events.isEmpty()) {
            return render(events)
        }
        if ((MonoTime.now() - lastWriteNanos) > Duration.second * 15) {
            lastWriteNanos = MonoTime.now()
            return ': ping\n\n'.toArray()
        }
        Array<Byte>()
    }

    private func render(events: ArrayList<JsonObject>): Array<Byte> {
        let builder = StringBuilder()
        for (event in events) {
            builder.append('event: message\n')
            builder.append('data: ${event.toString()}\n\n')
        }
        lastWriteNanos = MonoTime.now()
        builder.toString().toArray()
    }
}
