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

import std.collection.{ArrayList, HashMap}
import std.io.IOException
import std.sync.AtomicInt64
import stdx.net.http.*
import fountain::f_data.*
import fountain::f_jsonrpc.base.*

public struct ClientOptions {
    public ClientOptions(public let timeout!: Duration = Duration.second * 30,
        public let headers!: HashMap<String, String> = HashMap<String, String>(),
        public let maxResponseBytes!: Int64 = 8 * 1024 * 1024, public let keepAlive!: Bool = true,
        /** 只对连接建立失败重试；超时不重试（可能已经执行过） */
        public let retryOnConnectFailure!: Int64 = 0) {}
}

/** 批量调用的一条输入。 */
public struct JsonRpcCall {
    public const JsonRpcCall(public let method: String, public let params!: ?JsonValue = None) {}
}

/** 批量调用的一条响应。 */
public struct JsonRpcResponse {
    public const JsonRpcResponse(public let id: ?JsonValue, public let result: ?JsonValue,
        public let error: ?JsonRpcError) {}

    public prop isError: Bool {
        get() {
            error.isSome()
        }
    }
}

interface JsonRpcTransport {
    func send(body: Array<Byte>): Array<Byte>
    func close(): Unit
}

/**
 * JSON-RPC 客户端。默认复用 `stdx.net.http.Client` 的连接池，默认不重试。
 * 服务端返回的 `error` 抛 `JsonRpcException`；传输失败才抛 `IOException`。
 */
public class JsonRpcClient {
    private let transport: JsonRpcTransport
    private let maxRetries: Int64
    private let nextId = AtomicInt64(0)

    public init(url: String, opts!: ClientOptions = ClientOptions()) {
        this.transport = HttpJsonRpcTransport(url, opts)
        this.maxRetries = opts.retryOnConnectFailure
    }

    init(transport: JsonRpcTransport) {
        this.transport = transport
        this.maxRetries = 0
    }

    public func call(method: String, params!: ?JsonValue = None): JsonValue {
        let id = newId()
        let request = requestBody(method, params, Some(id))
        let bytes = sendWithRetry(request.toString().unsafeBytes())
        let response = toResponse(parseObject(bytes))
        if (let Some(error) <- response.error) {
            throw JsonRpcException(error.code, error.message, data: error.data)
        }
        match (response.result) {
            case Some(result) => result
            case _ => throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                'malformed json-rpc response: missing result')
        }
    }

    public func callAsync(method: String, params!: ?JsonValue = None): Future<JsonValue> {
        spawn {
            call(method, params: params)
        }
    }

    /** 通知：发送请求后立即返回，不解析响应，也不把服务端错误抛给调用方。 */
    public func notify(method: String, params!: ?JsonValue = None): Unit {
        let request = requestBody(method, params, None)
        let _ = sendWithRetry(request.toString().unsafeBytes())
    }

    /** 批量调用：返回与输入同序的响应（含每条的错误）。 */
    public func batch(calls: Array<JsonRpcCall>): Array<JsonRpcResponse> {
        let ids = ArrayList<JsonValue>()
        let requests = ArrayList<JsonValue>()
        for (call in calls) {
            let id = newId()
            ids.add(id)
            requests.add(requestBody(call.method, call.params, Some(id)))
        }
        let bytes = sendWithRetry(JsonArray(list: requests).toString().unsafeBytes())
        let parsed = JsonValue.fromBytes(bytes)
        let byId = HashMap<String, JsonRpcResponse>()
        if (let array: JsonArray <- parsed) {
            for (item in array) {
                if (let obj: JsonObject <- item) {
                    let response = toResponse(obj)
                    match (response.id) {
                        case Some(id) => byId.add(id.toString(), response)
                        case _ => ()
                    }
                }
            }
        }
        let responses = ArrayList<JsonRpcResponse>()
        for (id in ids) {
            match (byId.get(id.toString())) {
                case Some(response) => responses.add(response)
                case _ => responses.add(
                    JsonRpcResponse(Some(id), None,
                        Some(
                            JsonRpcError(JsonRpcProtocol.INTERNAL_ERROR, 'missing response for id ${id.toString()}',
                                None))))
            }
        }
        responses.toArray()
    }

    public func close(): Unit {
        transport.close()
    }

    /** 只对连接建立失败重试（IOException）；超时不重试——可能已经执行过。 */
    private func sendWithRetry(body: Array<Byte>): Array<Byte> {
        var attempt = 0
        while (true) {
            try {
                return transport.send(body)
            } catch (e: IOException) {
                if (attempt >= maxRetries) {
                    throw e
                }
                attempt++
            }
        }
        throw IOException('unreachable')
    }

    private func newId(): JsonValue {
        JsonInt(nextId.fetchAdd(1) + 1)
    }

    private func requestBody(method: String, params: ?JsonValue, id: ?JsonValue): JsonObject {
        let obj = JsonObject()
        obj.add('jsonrpc', JsonRpcProtocol.VERSION)
        match (id) {
            case Some(value) => obj.add('id', value)
            case _ => ()
        }
        obj.add('method', method)
        match (params) {
            case Some(value) => obj.add('params', value)
            case _ => ()
        }
        obj
    }

    private func parseObject(bytes: Array<Byte>): JsonObject {
        match (JsonValue.fromBytes(bytes)) {
            case obj: JsonObject => obj
            case _ => throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                'malformed json-rpc response: expected an object')
        }
    }

    private func toResponse(obj: JsonObject): JsonRpcResponse {
        let id = obj.get('id')
        match (obj.get('error')) {
            case Some(errorValue) =>
                if (let errorObj: JsonObject <- errorValue) {
                    let code = match (errorObj.get('code')) {
                        case Some(value) => value.asInt().toInt64()
                        case _ => JsonRpcProtocol.INTERNAL_ERROR
                    }
                    let message = match (errorObj.get('message')) {
                        case Some(value) =>
                            if (value is JsonString) {
                                value.asString().value
                            } else {
                                'Error'
                            }
                        case _ => 'Error'
                    }
                    JsonRpcResponse(id, None, Some(JsonRpcError(code, message, errorObj.get('data'))))
                } else {
                    JsonRpcResponse(id, None,
                        Some(JsonRpcError(JsonRpcProtocol.INTERNAL_ERROR, 'malformed error object', None)))
                }
            case _ => JsonRpcResponse(id, obj.get('result'), None)
        }
    }
}

class HttpJsonRpcTransport <: JsonRpcTransport {
    private let client: Client
    private let url: String
    private let opts: ClientOptions

    HttpJsonRpcTransport(url: String, opts: ClientOptions) {
        this.url = url
        this.opts = opts
        this.client = ClientBuilder().readTimeout(opts.timeout).writeTimeout(opts.timeout).build()
    }

    public func send(body: Array<Byte>): Array<Byte> {
        var builder = HttpRequestBuilder()
            .method('POST')
            .url(url)
            .header('Content-Type', 'application/json; charset=utf-8')
            .header('Accept', 'application/json')
        if (!opts.keepAlive) {
            builder = builder.header('Connection', 'close')
        }
        for ((name, value) in opts.headers) {
            builder = builder.header(name, value)
        }
        let response = client.send(builder.body(body).build())
        try {
            let bytes = readAll(response)
            if (bytes.size > opts.maxResponseBytes) {
                throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                    'response body exceeds ${opts.maxResponseBytes} bytes')
            }
            bytes
        } catch (e: Exception) {
            // body 没读完就放弃时才需要关连接；正常读完由连接池复用。
            response.close()
            throw e
        }
    }

    public func close(): Unit {
        client.close()
    }

    private func readAll(response: HttpResponse): Array<Byte> {
        let bytes = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let size = response.body.read(buffer)
            if (size <= 0) {
                break
            }
            bytes.add(all: buffer[0..size])
        }
        bytes.unsafeData()
    }
}
