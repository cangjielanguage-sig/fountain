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
package fountain::f_mcp.client

import std.collection.{ArrayList, HashMap}
import std.io.*
import std.process.*
import std.sync.Mutex
import stdx.log.LogLevel
import fountain::f_data.*
import fountain::f_jsonrpc.base.{JsonRpcException, JsonRpcProtocol}
import fountain::f_jsonrpc.client.{ClientOptions, JsonRpcClient}
import fountain::f_log.impl.*
import fountain::f_mcp.base.*

public class McpClientOptions {
    public var timeout: Duration = Duration.second * 30
    public var protocolVersion = McpProtocol.VERSION
    public var clientName = 'fountain-mcp-client'
    public var clientVersion = '1.0.0'
    public var capabilities: JsonObject = JsonObject()
    public var maxRounds: Int64 = 8
    /** 每个 HTTP 请求附带的头（如 `Authorization`）；stdio 传输忽略。 */
    public var headers = HashMap<String, String>()
    /** 响应体上限，超限抛错；stdio 传输忽略。 */
    public var maxResponseBytes: Int64 = 8 * 1024 * 1024
    /** HTTP keep-alive；stdio 传输忽略。 */
    public var keepAlive = true
    /** 建连失败重试次数（读响应失败不重试）。 */
    public var retryOnConnectFailure: Int64 = 0

    public init() {}

    /** 映射为 f_jsonrpc 的客户端选项。 */
    public func toJsonRpcOptions(): ClientOptions {
        ClientOptions(timeout: timeout, headers: headers, maxResponseBytes: maxResponseBytes, keepAlive: keepAlive,
            retryOnConnectFailure: retryOnConnectFailure)
    }
}

/** 一条 `tools/call` 的结果（客户端视角）。 */
public struct McpCallToolResult {
    public const McpCallToolResult(public let content: JsonArray, public let structuredContent: ?JsonValue,
        public let isError: Bool, public let resultType: String, public let inputRequired: ?JsonValue,
        public let requestState!: ?JsonValue = None) {}
}

interface McpRpc {
    func call(method: String, params: ?JsonValue): JsonValue
    func close(): Unit
}

class HttpMcpRpc <: McpRpc {
    private let client: JsonRpcClient

    init(url: String, opts: McpClientOptions) {
        client = JsonRpcClient(url, opts: opts.toJsonRpcOptions())
    }

    public func call(method: String, params: ?JsonValue): JsonValue {
        client.call(method, params: params)
    }

    public func close(): Unit {
        client.close()
    }
}

/** stdio 传输：一行一个 JSON-RPC 消息，stderr 单独消费。 */
class StdioMcpRpc <: McpRpc {
    static let log = LoggerFactory.getLogger<StdioMcpRpc>()

    private let process: SubProcess
    private let reader: StringReader<InputStream>
    private let mutex = Mutex()

    init(command: String, args: Array<String>) {
        process = launch(command, args, stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        reader = StringReader<InputStream>(process.stdOutPipe)
        spawn {
            consumeStderr(process.stdErrPipe)
        }
    }

    public func call(method: String, params: ?JsonValue): JsonValue {
        synchronized(mutex) {
            let request = JsonObject()
            request.add('jsonrpc', JsonRpcProtocol.VERSION)
            request.add('id', 1)
            request.add('method', method)
            match (params) {
                case Some(value) => request.add('params', value)
                case _ => ()
            }
            process.stdInPipe.write((request.toString() + '\n').toArray())
            process.stdInPipe.flush()
            match (reader.readln()) {
                case Some(line) =>
                    let value = JsonValue.fromStr(line)
                    match (value) {
                        case obj: JsonObject =>
                            if (let Some(error) <- obj.get('error')) {
                                let e = error.asObject()
                                throw McpException(e['code'].asInt().toInt64(), e['message'].asString().value,
                                    data: e.get('data'))
                            }
                            obj.get('result') ?? JsonNull.instance
                        case _ => throw McpException(McpProtocol.INTERNAL_ERROR, 'malformed stdio response')
                    }
                case _ => throw McpException(McpProtocol.INTERNAL_ERROR, 'stdio server closed the stream')
            }
        }
    }

    public func close(): Unit {
        try {
            match (process.stdInPipe) {
                case resource: Resource => resource.close()
                case _ => ()
            }
        } catch (_: Exception) {}
        try {
            process.terminate()
        } catch (_: Exception) {}
        let _ = process.wait(timeout: Duration.second * 2)
    }

    private static func consumeStderr(stream: InputStream): Unit {
        let reader = StringReader<InputStream>(stream)
        while (let Some(line) <- reader.readln()) {
            log.append(LogLevel.WARN, 'mcp stdio stderr: ${line}', None<Exception>)
        }
    }
}

/**
 * MCP 客户端。HTTP 用 `f_jsonrpc.JsonRpcClient`；stdio 用子进程；
 * 每次请求自动注入 `_meta`，`-32022` 只重试一次。
 */
public class McpClient {
    static let log = LoggerFactory.getLogger<McpClient>()

    private let rpc: McpRpc
    private let options: McpClientOptions
    private let versionMutex = Mutex()
    private var protocolVersion: String

    public init(url: String, options!: McpClientOptions = McpClientOptions()) {
        this.rpc = HttpMcpRpc(url, options)
        this.options = options
        this.protocolVersion = options.protocolVersion
    }

    public static func http(url: String, options!: McpClientOptions = McpClientOptions()): McpClient {
        McpClient(url, options: options)
    }

    public static func stdio(command: String, args!: Array<String> = Array<String>(),
        options!: McpClientOptions = McpClientOptions()): McpClient {
        McpClient(StdioMcpRpc(command, args), options)
    }

    init(rpc: McpRpc, options: McpClientOptions) {
        this.rpc = rpc
        this.options = options
        this.protocolVersion = options.protocolVersion
    }

    public func discover(): JsonObject {
        rpcCall('server/discover', None).asObject()
    }

    public func listTools(cursor!: ?String = None): JsonObject {
        let params = JsonObject()
        match (cursor) {
            case Some(value) => params.add('cursor', value)
            case _ => ()
        }
        rpcCall('tools/list', params).asObject()
    }

    public func listAllTools(): ArrayList<JsonValue> {
        let all = ArrayList<JsonValue>()
        var cursor: ?String = None
        var rounds = 0
        while (rounds < 100 && all.size < 1000) {
            let page = listTools(cursor: cursor)
            if (let Some(tools) <- page.get('tools')) {
                if (let array: JsonArray <- tools) {
                    for (tool in array) {
                        all.add(tool)
                    }
                }
            }
            match (page.get('nextCursor')) {
                case Some(value) =>
                    if (value is JsonString) {
                        cursor = Some(value.asString().value)
                    } else {
                        cursor = None
                    }
                case _ => cursor = None
            }
            if (cursor.isNone()) {
                break
            }
            rounds++
        }
        if (cursor.isSome()) {
            throw McpException(McpProtocol.INTERNAL_ERROR, 'tools/list pagination exceeded 100 pages')
        }
        all
    }

    public func callTool(name: String, arguments!: JsonValue = JsonObject()): McpCallToolResult {
        let params = JsonObject()
        params.add('name', name)
        params.add('arguments', arguments)
        let result = rpcCall('tools/call', params).asObject()
        toCallToolResult(result)
    }

    /**
     * `input_required` 自动多轮：handler 拿到 `inputRequired`，返回 `inputResponses`。
     */
    public func callToolAuto(name: String, arguments!: JsonValue = JsonObject(), handler!: (JsonValue) -> JsonValue,
        maxRounds!: Int64 = 0): McpCallToolResult {
        let limit = if (maxRounds > 0) {
            maxRounds
        } else {
            options.maxRounds
        }
        var inputResponses: ?JsonValue = None
        var requestState: ?JsonValue = None
        var round = 0
        while (round < limit) {
            let params = JsonObject()
            params.add('name', name)
            params.add('arguments', arguments)
            match (inputResponses) {
                case Some(value) => params.add('inputResponses', value)
                case _ => ()
            }
            match (requestState) {
                case Some(value) => params.add('requestState', value)
                case _ => ()
            }
            let result = toCallToolResult(rpcCall('tools/call', params).asObject())
            if (result.resultType != 'input_required') {
                return result
            }
            let input = result.inputRequired ?? JsonNull.instance
            inputResponses = Some(handler(input))
            // 下一轮必须把服务端给的状态原样带回去，多轮才能收敛
            requestState = result.requestState
            round++
        }
        throw McpException(McpProtocol.INTERNAL_ERROR, "tool '${name}' still requires input after ${limit} rounds")
    }

    public func listResources(cursor!: ?String = None): JsonObject {
        let params = JsonObject()
        match (cursor) {
            case Some(value) => params.add('cursor', value)
            case _ => ()
        }
        rpcCall('resources/list', params).asObject()
    }

    public func readResource(uri: String): JsonObject {
        let params = JsonObject()
        params.add('uri', uri)
        rpcCall('resources/read', params).asObject()
    }

    public func listPrompts(cursor!: ?String = None): JsonObject {
        let params = JsonObject()
        match (cursor) {
            case Some(value) => params.add('cursor', value)
            case _ => ()
        }
        rpcCall('prompts/list', params).asObject()
    }

    /** 注册订阅；返回结果里的 `sseUrl` 可直接用于建立 SSE 连接。 */
    public func listen(topics: Array<String>): JsonObject {
        let params = JsonObject()
        let array = JsonArray()
        for (topic in topics) {
            array.add(topic)
        }
        params.add('topics', array)
        rpcCall('subscriptions/listen', params).asObject()
    }

    public func getPrompt(name: String, arguments!: JsonObject = JsonObject()): JsonObject {
        let params = JsonObject()
        params.add('name', name)
        params.add('arguments', arguments)
        rpcCall('prompts/get', params).asObject()
    }

    public func close(): Unit {
        rpc.close()
    }

    private func rpcCall(method: String, params: ?JsonValue, tried!: ?String = None): JsonValue {
        let version = currentVersion()
        let merged = withMeta(params, version)
        try {
            return rpc.call(method, merged)
        } catch (e: McpException) {
            if (e.code == McpProtocol.UNSUPPORTED_VERSION && tried.isNone()) {
                negotiate(version, e)
                return rpcCall(method, params, tried: version)
            }
            throw e
        } catch (e: JsonRpcException) {
            if (e.code == McpProtocol.UNSUPPORTED_VERSION && tried.isNone()) {
                negotiate(version, e)
                return rpcCall(method, params, tried: version)
            }
            throw McpException(e.code, e.message, data: e.data)
        } catch (e: IOException) {
            throw McpException(McpProtocol.INTERNAL_ERROR, 'transport failed: ${e.message}')
        }
    }

    private func currentVersion(): String {
        synchronized(versionMutex) {
            protocolVersion
        }
    }

    private func withMeta(params: ?JsonValue, version: String): JsonObject {
        let obj = JsonObject()
        match (params) {
            case Some(source: JsonObject) => for ((key, value) in source) {
                obj.add(key, value)
            }
            case _ => ()
        }
        let meta = JsonObject()
        meta.add(McpProtocol.KEY_PROTOCOL_VERSION, version)
        let info = JsonObject()
        info.add('name', options.clientName)
        info.add('version', options.clientVersion)
        meta.add(McpProtocol.KEY_CLIENT_INFO, info)
        meta.add(McpProtocol.KEY_CLIENT_CAPABILITIES, options.capabilities)
        obj.add(McpProtocol.META, meta)
        obj
    }

    /**
     * 协商新版本。只有「当前版本还等于本次请求使用的版本」时才改写，
     * 并发命中 `-32022` 的请求不会各自覆盖一遍。
     */
    private func negotiate(usedVersion: String, error: JsonRpcException): Unit {
        let next = supportedVersionOf(error)
        synchronized(versionMutex) {
            if (protocolVersion != usedVersion) {
                return
            }
            protocolVersion = next
        }
        log.append(LogLevel.INFO, "mcp protocol version negotiated: ${usedVersion} -> ${next}", None<Exception>)
    }

    private func supportedVersionOf(error: JsonRpcException): String {
        match (error.data) {
            case Some(data) =>
                if (let obj: JsonObject <- data) {
                    if (let Some(supported) <- obj.get('supported')) {
                        if (let array: JsonArray <- supported) {
                            if (array.size > 0 && array[0] is JsonString) {
                                return array[0].asString().value
                            }
                        }
                    }
                }
                throw McpException(error.code, error.message, data: error.data)
            case _ => throw McpException(error.code, error.message)
        }
    }

    private static func toCallToolResult(obj: JsonObject): McpCallToolResult {
        let content = match (obj.get('content')) {
            case Some(array: JsonArray) => array
            case _ => JsonArray()
        }
        let isError = match (obj.get('isError')) {
            case Some(value) =>
                if (value is JsonBool) {
                    value.asBool().value
                } else {
                    false
                }
            case _ => false
        }
        let resultType = match (obj.get('resultType')) {
            case Some(value) =>
                if (value is JsonString) {
                    value.asString().value
                } else {
                    'complete'
                }
            case _ => 'complete'
        }
        McpCallToolResult(content, obj.get('structuredContent'), isError, resultType, obj.get('inputRequired'),
            requestState: obj.get('requestState'))
    }
}
