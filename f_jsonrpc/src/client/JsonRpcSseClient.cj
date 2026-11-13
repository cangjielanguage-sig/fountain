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
package fountain::f_jsonrpc.client

import std.collection.*

import fountain::f_data.*
import fountain::f_httpclient.sse.*
import fountain::f_jsonrpc.base.*

/** 一条 SSE 连接：`next` 返回一个事件，`None` 表示连接结束 */
public interface SseConnection {
    func next(): ?SseEvent
    func close(): Unit
}

/**
 * SSE 客户端：把服务端推送的事件解析成 JSON-RPC 通知。
 *
 * 与 `JsonRpcClient` 并列而不合并：一个是「发一问收一答」，一个是长连接流，
 * 生命周期与重连语义完全不同，混在一个类里会互相污染状态。
 *
 * 断线时带 `Last-Event-ID` 重连，最多 [retry] 次；超过则抛 `JsonRpcConnectException`，
 * **不静默结束**（静默结束会让调用方以为「服务端正常收尾」）。
 */
public class JsonRpcSseClient {
    private let connect: (HashMap<String, String>) -> ?SseConnection
    private let retry: Int64
    private let headers: HashMap<String, String>
    private var connection: ?SseConnection = None
    private var lastEventId: Int64 = 0
    private var closed: Bool = false

    /** 生产用法：由 url/topic/taskId 建连接 */
    public init(url: String, topic!: String = '', taskId!: String = '', retry!: Int64 = 3,
                headers!: HashMap<String, String> = HashMap<String, String>()) {
        this.connect = { extra =>
            SocketSseConnection.open(url, topic, taskId, extra)
        }
        this.retry = retry
        this.headers = headers
    }

    /** 测试用法：注入连接工厂（每次重连都会调用一次） */
    init(connect: (HashMap<String, String>) -> ?SseConnection, retry!: Int64 = 3) {
        this.connect = connect
        this.retry = retry
        this.headers = HashMap<String, String>()
    }

    /** 取下一条通知；连接正常结束返回 `None` */
    public func next(): ?JsonValue {
        while (true) {
            match (connection) {
                case Some(current) => match (current.next()) {
                    case Some(event) =>
                        if (!event.id.isEmpty()) {
                            match (Int64.tryParse(event.id.trimAscii())) {
                                case Some(value) =>
                                    if (value > lastEventId) {
                                        lastEventId = value
                                    }
                                case None => ()
                            }
                        }
                        match (parseOf(event.data)) {
                            case Some(value) => return Some(value)
                            // 坏帧不掐断整条流：跳过它，继续等下一条
                            case None => ()
                        }
                    case None =>
                        current.close()
                        connection = None
                        if (!reconnect()) {
                            return None
                        }
                }
                case None =>
                    if (!reconnect()) {
                        return None
                    }
            }
        }
        return None
    }

    public func close(): Unit {
        closed = true
        match (connection) {
            case Some(current) => current.close()
            case None => ()
        }
        connection = None
    }

    /** 重连一次；用尽重试次数抛错（不静默返回 None） */
    private func reconnect(): Bool {
        if (closed) {
            return false
        }
        var attempt: Int64 = 0
        while (attempt < retry) {
            attempt++
            let extra = HashMap<String, String>()
            for ((key, value) in headers) {
                extra[key] = value
            }
            if (lastEventId > 0) {
                extra['Last-Event-ID'] = lastEventId.toString()
            }
            match (connect(extra)) {
                case Some(value) =>
                    connection = Some(value)
                    return true
                case None => ()
            }
        }
        if (retry <= 0) {
            throw JsonRpcConnectException('sse reconnect disabled (retry=${retry})')
        }
        throw JsonRpcConnectException('sse reconnect failed after ${retry} attempts')
    }

    /**
     * 只接受 JSON-RPC 通知（对象）。
     *
     * 注意：`JsonValue.fromStr` 对 `not json` 这类输入**不抛异常**，会退化成 `JsonNull`，
     * 所以还得校验「是对象」——否则脏帧会让调用方拿到一个 `JsonNull` 并在 `asObject()` 处炸掉。
     */
    private static func parseOf(data: String): ?JsonValue {
        let value = try {
            JsonValue.fromStr(data)
        } catch (e: Exception) {
            return None
        }
        try {
            let _ = value.asObject()
            Some(value)
        } catch (e: Exception) {
            None
        }
    }
}
