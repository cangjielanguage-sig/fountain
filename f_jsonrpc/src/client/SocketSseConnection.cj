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

import fountain::f_httpclient.*
import fountain::f_jsonrpc.base.*

/**
 * 一条真实的 SSE 连接：HTTP 与分帧都复用 `f_httpclient`。
 *
 * - 建连与读响应体：`HttpClient(url).get()`（响应体本身就是流）；
 * - 分帧：`f_httpclient.sse.SseReader`（注释丢弃、空行分隔、`data` 多行拼接）；
 * - 本类只做「取下一个事件」，不解析 JSON、不管重连（那是 `JsonRpcSseClient` 的事）。
 *
 * `Last-Event-ID` 走查询参数 `cursor`：`HttpClient` 没有暴露请求头入口，
 * 而服务端两种方式都支持，语义等价。
 */
public class SocketSseConnection <: SseConnection {
    private let client: HttpClient
    private let reader: SseReader

    private init(client: HttpClient, reader: SseReader) {
        this.client = client
        this.reader = reader
    }

    public static func open(url: String, topic: String, taskId: String,
                            headers: HashMap<String, String>): ?SseConnection {
        var full = url
        let separator = if (url.contains('?')) {
            '&'
        } else {
            '?'
        }
        full += '${separator}topic=${topic}&taskId=${taskId}'
        match (headers.get('Last-Event-ID')) {
            case Some(value) => full += '&cursor=${value}'
            case None => ()
        }
        let client = HttpClient(full)
        try {
            let response = client.get()
            Some(SocketSseConnection(client, SseReader(response.body)))
        } catch (e: Exception) {
            client.close()
            None
        }
    }

    /** 取一个事件；连接结束时返回 `None` */
    public func next(): ?SseEvent {
        reader.next()
    }

    public func close(): Unit {
        reader.close()
        client.close()
    }
}
