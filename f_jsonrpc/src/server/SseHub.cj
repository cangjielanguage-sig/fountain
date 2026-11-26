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
package fountain::f_jsonrpc.server

import std.collection.*
import std.sync.*
import std.time.*

import fountain::f_data.*

/** 一次 SSE 订阅：持有一条 `SseStream` 与它关心的 `taskId`（空表示不过滤） */
public class SseSubscription {
    public let id: Int64
    public let stream: SseStream
    public let taskId: String

    init(id: Int64, stream: SseStream, taskId: String) {
        this.id = id
        this.stream = stream
        this.taskId = taskId
    }

    public func close(): Unit {
        stream.close()
    }
}

/**
 * 进程级 SSE 发布/订阅。
 *
 * - 事件 id 在同一 `topic` 下单调递增：`Last-Event-ID` 只需「取大于它的」，不用管订阅者各自的进度；
 * - 每个 topic 保留最近 [REPLAY_CAPACITY] 条用于断线补发。
 */
public class SseHub {
    private static let mutex = Mutex()
    private static var nextId: Int64 = 0
    private static var nextSubId: Int64 = 0
    private static let subscribers = HashMap<String, ArrayList<SseSubscription>>()
    private static let recent = HashMap<String, ArrayList<SseEvent>>()

    private init() {
    }

    /** 订阅：立即补发 id 大于 `lastEventId` 的历史事件（命中缓冲范围内） */
    public static func subscribe(topic: String, taskId!: String = '',
                                 lastEventId!: Int64 = 0): SseSubscription {
        let stream = SseStream()
        let subscription = synchronized(mutex) {
            nextSubId++
            let item = SseSubscription(nextSubId, stream, taskId)
            match (subscribers.get(topic)) {
                case Some(list) => list.add(item)
                case None =>
                    let list = ArrayList<SseSubscription>()
                    list.add(item)
                    subscribers[topic] = list
            }
            // 补发：按 taskId 过滤后回放
            match (recent.get(topic)) {
                case Some(events) =>
                    for (event in events) {
                        if (event.id > lastEventId && matches(item, event.taskId)) {
                            let _ = stream.push(event.frame)
                        }
                    }
                case None => ()
            }
            item
        }
        subscription
    }

    /**
     * 发布一条 JSON-RPC 通知事件。
     *
     * @param taskId 便于订阅者按任务过滤；空表示广播给该 topic 的所有订阅者
     * @return 事件 id（单调递增）
     */
    public static func publish(topic: String, method: String, params!: ?JsonValue = None,
                               taskId!: String = ''): Int64 {
        let frame = synchronized(mutex) {
            nextId++
            let id = nextId
            let text = frameOf(id, method, params)
            let event = SseEvent(id, taskId, text)
            match (recent.get(topic)) {
                case Some(events) =>
                    events.add(event)
                    while (Int64(events.size) > REPLAY_CAPACITY) {
                        events.remove(at: 0)
                    }
                case None =>
                    let events = ArrayList<SseEvent>()
                    events.add(event)
                    recent[topic] = events
            }
            for (item in subscribersOf(topic)) {
                if (matches(item, taskId)) {
                    let _ = item.stream.push(text)
                }
            }
            id
        }
        frame
    }

    public static func subscriberCount(topic: String): Int64 {
        synchronized(mutex) {
            match (subscribers.get(topic)) {
                case Some(list) => Int64(list.size)
                case None => 0
            }
        }
    }

    /** 测试用：清空订阅与缓冲，id 重置 */
    public static func reset(): Unit {
        synchronized(mutex) {
            subscribers.clear()
            recent.clear()
            nextId = 0
            nextSubId = 0
        }
    }

    private static func subscribersOf(topic: String): ArrayList<SseSubscription> {
        match (subscribers.get(topic)) {
            case Some(list) => list
            case None => ArrayList<SseSubscription>()
        }
    }

    private static func matches(subscription: SseSubscription, taskId: String): Bool {
        subscription.taskId.isEmpty() || taskId.isEmpty() || subscription.taskId == taskId
    }

    /** SSE 帧：`id` / `event` / `data`，`data` 是 JSON-RPC 2.0 通知 */
    private static func frameOf(id: Int64, method: String, params: ?JsonValue): String {
        let body = JsonObject()
        body.add('jsonrpc', '2.0')
        body.add('method', method)
        match (params) {
            case Some(value) => body.add('params', value)
            case None => ()
        }
        'id: ${id}\nevent: message\ndata: ${body.toString()}\n\n'
    }

    private static let REPLAY_CAPACITY: Int64 = 256
}

/** 已发布的事件（补发用） */
class SseEvent {
    public let id: Int64
    public let taskId: String
    public let frame: String

    init(id: Int64, taskId: String, frame: String) {
        this.id = id
        this.taskId = taskId
        this.frame = frame
    }
}
