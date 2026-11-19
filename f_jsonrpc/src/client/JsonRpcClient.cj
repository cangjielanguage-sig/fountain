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
        /** 只对连接建立失败重试；读响应阶段的失败不重试（服务端可能已经执行过） */
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

/**
 * 传输 SPI。`send` 只负责「把请求体发出去、把响应体读回来」，
 * 建连 / 发送阶段失败抛 `JsonRpcConnectException`（可重试），读响应阶段失败抛普通异常（不可重试）。
 */
public interface JsonRpcTransport {
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

    /** 注入自定义传输（stdio / 测试替身）。`maxRetries` 取自 `opts.retryOnConnectFailure`。 */
    public init(transport: JsonRpcTransport, opts!: ClientOptions = ClientOptions()) {
        this.transport = transport
        this.maxRetries = opts.retryOnConnectFailure
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
        let parsed = parseValue(bytes)
        let byId = HashMap<String, JsonRpcResponse>()
        match (parsed) {
            case array: JsonArray =>
                for (item in array) {
                    if (let obj: JsonObject <- item) {
                        let response = toResponse(obj)
                        match (response.id) {
                            case Some(id) => byId.add(id.toString(), response)
                            case _ => ()
                        }
                    }
                }
            case obj: JsonObject => match (obj.get('error')) {
                    // 服务端整体拒绝（-32003 批量超限 / -32600 空批量）：原样抛出，不合成 N 条 -32603
                    case Some(errorValue) =>
                        let error = toError(errorValue)
                        throw JsonRpcException(error.code, error.message, data: error.data)
                    case _ => throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                        'malformed batch response: expected an array')
                }
            case _ => throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                'malformed batch response: expected an array')
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

    /** 只对建连 / 发送阶段失败重试；读响应失败不重试——服务端可能已经执行过。 */
    private func sendWithRetry(body: Array<Byte>): Array<Byte> {
        var attempt = 0
        while (true) {
            try {
                return transport.send(body)
            } catch (e: JsonRpcConnectException) {
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

    /** 解析响应体：任何解析失败都转成 `JsonRpcException`，不让 `JsonException` 穿透。 */
    private func parseValue(bytes: Array<Byte>): JsonValue {
        try {
            JsonValue.fromBytes(bytes)
        } catch (e: Exception) {
            throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR, 'malformed json-rpc response: ${e.message}')
        }
    }

    private func parseObject(bytes: Array<Byte>): JsonObject {
        match (parseValue(bytes)) {
            case obj: JsonObject => obj
            case _ => throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                'malformed json-rpc response: expected an object')
        }
    }

    private func toResponse(obj: JsonObject): JsonRpcResponse {
        let id = obj.get('id')
        match (obj.get('error')) {
            case Some(errorValue) => JsonRpcResponse(id, None, Some(toError(errorValue)))
            case _ => JsonRpcResponse(id, obj.get('result'), None)
        }
    }

    /** `error` 必须是对象；`code` 必须是数字。非法形态一律收敛成 `-32603`。 */
    private func toError(value: JsonValue): JsonRpcError {
        var errorObj: JsonObject
        match (value) {
            case obj: JsonObject => errorObj = obj
            case _ => return JsonRpcError(JsonRpcProtocol.INTERNAL_ERROR, 'malformed error object', None)
        }
        let message = match (errorObj.get('message')) {
            case Some(m: JsonString) => m.value
            case _ => 'Error'
        }
        var code = JsonRpcProtocol.INTERNAL_ERROR
        match (errorObj.get('code')) {
            case Some(i: JsonInt) => code = i.toInt64()
            case Some(d: JsonDecimal) => code = d.toInt64()
            case _ => return JsonRpcError(JsonRpcProtocol.INTERNAL_ERROR, message, errorObj.get('data'))
        }
        JsonRpcError(code, message, errorObj.get('data'))
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
        // 建连 / 发送阶段失败才可重试
        let response = try {
            client.send(builder.body(body).build())
        } catch (e: Exception) {
            throw JsonRpcConnectException('${e.message}')
        }
        // 读响应阶段失败不重试：服务端可能已经执行过
        try {
            let cap = opts.maxResponseBytes
            match (declaredLength(response)) {
                case Some(declared) =>
                    if (declared > cap) {
                        throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR,
                            'response body exceeds ${cap} bytes (declared ${declared})')
                    }
                case _ => ()
            }
            readCapped(response, cap)
        } catch (e: Exception) {
            // body 没读完就放弃时才需要关连接；正常读完由连接池复用。
            try {
                response.close()
            } catch (_: Exception) {
                ()
            }
            throw e
        }
    }

    public func close(): Unit {
        client.close()
    }

    private func declaredLength(response: HttpResponse): ?Int64 {
        match (response.headers.getFirst('Content-Length')) {
            case Some(text) =>
                try {
                    Some(Int64.parse(text.trimAscii()))
                } catch (_: Exception) {
                    None<Int64>
                }
            case _ => None<Int64>
        }
    }

    /** 流式读取并累计字节数，超过 `cap` 立即停止（不分配整包内存）。 */
    private func readCapped(response: HttpResponse, cap: Int64): Array<Byte> {
        var initial: Int64 = 8192
        match (declaredLength(response)) {
            case Some(declared) =>
                if (declared > 0 && declared <= cap) {
                    initial = declared
                }
            case _ => ()
        }
        let bytes = ArrayList<Byte>(initial)
        let buffer = Array<Byte>(8192, repeat: 0)
        var total: Int64 = 0
        while (true) {
            let size = response.body.read(buffer)
            if (size <= 0) {
                break
            }
            total += size
            if (total > cap) {
                throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR, 'response body exceeds ${cap} bytes')
            }
            bytes.add(all: buffer[0..size])
        }
        bytes.unsafeData()
    }
}
