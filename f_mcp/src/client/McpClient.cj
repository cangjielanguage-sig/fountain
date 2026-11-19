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
import std.time.MonoTime
import stdx.log.LogLevel
import fountain::f_data.*
import fountain::f_jsonrpc.base.JsonRpcException
import fountain::f_jsonrpc.client.{ClientOptions, JsonRpcClient, JsonRpcTransport}
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

/** `tools/call` 的结果：与 base 模型同源，`McpCallToolResult` 保留为源兼容别名。 */
public type McpCallToolResult = CallToolResult

interface McpRpc {
    func call(method: String, params: ?JsonValue): JsonValue
    func close(): Unit
}

/** HTTP 与 stdio 共用的 RPC 接缝：只包一个 `JsonRpcClient`，不重复实现消息层。 */
class JsonRpcMcpRpc <: McpRpc {
    private let client: JsonRpcClient

    init(client: JsonRpcClient) {
        this.client = client
    }

    public func call(method: String, params: ?JsonValue): JsonValue {
        client.call(method, params: params)
    }

    public func close(): Unit {
        client.close()
    }
}

/**
 * stdio 传输：一行一个 JSON-RPC 消息。
 *
 * 只负责「写一行、等 id 匹配的一行」，请求 id 由 `JsonRpcClient` 分配（单调递增）；
 * 服务端通知 / 请求 / 非 JSON 噪声行一律跳过，读超时抛 `IOException`。
 */
class StdioJsonRpcTransport <: JsonRpcTransport {
    static let log = LoggerFactory.getLogger<StdioJsonRpcTransport>()

    private let process: SubProcess
    private let timeout: Duration
    private let mutex = Mutex()
    private let cond = synchronized(mutex) {
        mutex.condition()
    }
    private let writeMutex = Mutex()
    private let lines = ArrayList<String>()
    private var closed = false

    init(command: String, args: Array<String>, timeout: Duration) {
        this.process = launch(command, args, stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        this.timeout = timeout
        let stdout = process.stdOutPipe
        spawn {
            consumeStdout(stdout)
        }
        spawn {
            consumeStderr(process.stdErrPipe)
        }
    }

    public func send(body: Array<Byte>): Array<Byte> {
        let requestId = idOf(body)
        synchronized(writeMutex) {
            process.stdInPipe.write(body)
            process.stdInPipe.write('\n'.unsafeBytes())
            process.stdInPipe.flush()
        }
        // 通知没有响应，写完即可返回
        match (requestId) {
            case None => return Array<Byte>()
            case _ => ()
        }
        let expected = requestId.getOrThrow()
        let start = MonoTime.now()
        synchronized(mutex) {
            while (true) {
                while (!lines.isEmpty()) {
                    let line = lines.remove(at: 0)
                    match (classify(line, expected)) {
                        case Response => return line.unsafeBytes()
                        case Skip => continue
                    }
                }
                if (closed) {
                    throw IOException('stdio server closed the stream')
                }
                let elapsed = MonoTime.now() - start
                if (elapsed >= timeout) {
                    throw IOException('stdio response timeout')
                }
                cond.wait(timeout: timeout - elapsed)
            }
            throw IOException('unreachable')
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (closed) {
                return
            }
            closed = true
            cond.notifyAll()
        }
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

    /** 判断一行是本次请求的响应，还是应跳过的通知 / 噪声。 */
    private func classify(line: String, expected: JsonValue): SkipKind {
        let parsed = try {
            JsonValue.fromStr(line)
        } catch (_: Exception) {
            log.append(LogLevel.WARN, 'non-json stdio output: ${line}', None<Exception>)
            return Skip
        }
        let obj = match (parsed) {
            case value: JsonObject => value
            case _ =>
                log.append(LogLevel.WARN, 'unexpected stdio output: ${line}', None<Exception>)
                return Skip
        }
        match (obj.get('id')) {
            case Some(id) =>
                if (id.toString() == expected.toString()) {
                    return Response
                }
                log.append(LogLevel.WARN, "stale stdio response id=${id.toString()}", None<Exception>)
                Skip
            case _ => match (obj.get('method')) {
                    case Some(method) =>
                        if (method is JsonString) {
                            let name = method.asString().value
                            if (name.startsWith('notifications/')) {
                                log.append(LogLevel.DEBUG, "stdio notification: ${name}", None<Exception>)
                            } else {
                                log.append(LogLevel.DEBUG, "ignored stdio request: ${name}", None<Exception>)
                            }
                        }
                        Skip
                    case _ =>
                        log.append(LogLevel.WARN, 'unexpected stdio output: ${line}', None<Exception>)
                        Skip
                }
        }
    }

    private func consumeStdout(stream: InputStream): Unit {
        let reader = StringReader<InputStream>(stream)
        try {
            while (let Some(line) <- reader.readln()) {
                synchronized(mutex) {
                    lines.add(line)
                    cond.notify()
                }
            }
        } catch (_: Exception) {
            ()
        }
        synchronized(mutex) {
            closed = true
            cond.notifyAll()
        }
    }

    private static func consumeStderr(stream: InputStream): Unit {
        let reader = StringReader<InputStream>(stream)
        while (let Some(line) <- reader.readln()) {
            log.append(LogLevel.WARN, 'mcp stdio stderr: ${line}', None<Exception>)
        }
    }

    private func idOf(body: Array<Byte>): ?JsonValue {
        let parsed = try {
            JsonValue.fromBytes(body)
        } catch (e: Exception) {
            throw IOException('malformed stdio request: ${e.message}')
        }
        match (parsed) {
            case obj: JsonObject => obj.get('id')
            case _ => throw IOException('malformed stdio request: expected an object')
        }
    }
}

/** `classify` 的判定结果。 */
enum SkipKind {
    | Response
    | Skip
}

/**
 * MCP 客户端。HTTP 与 stdio 都走 `f_jsonrpc.JsonRpcClient`；
 * 每次请求自动注入 `_meta`，`-32022` 只重试一次。
 */
public class McpClient {
    static let log = LoggerFactory.getLogger<McpClient>()

    private let rpc: McpRpc
    private let options: McpClientOptions
    private let versionMutex = Mutex()
    private var protocolVersion: String
    /**
     * 版本协商真正改写 `protocolVersion` 的次数。
     *
     * 并发命中 `-32022` 时各请求都拿着旧版本进入 `negotiate`，但只有一个能改写；
     * 这个计数是「只改写一次」的可观测出口（同时对应唯一一条 INFO 日志）。
     */
    var versionRewrites = 0

    public init(url: String, options!: McpClientOptions = McpClientOptions()) {
        this.rpc = JsonRpcMcpRpc(JsonRpcClient(url, opts: options.toJsonRpcOptions()))
        this.options = options
        this.protocolVersion = options.protocolVersion
    }

    public static func http(url: String, options!: McpClientOptions = McpClientOptions()): McpClient {
        McpClient(url, options: options)
    }

    public static func stdio(command: String, args!: Array<String> = Array<String>(),
        options!: McpClientOptions = McpClientOptions()): McpClient {
        let transport = StdioJsonRpcTransport(command, args, options.timeout)
        McpClient(JsonRpcMcpRpc(JsonRpcClient(transport, opts: options.toJsonRpcOptions())), options)
    }

    init(rpc: McpRpc, options: McpClientOptions) {
        this.rpc = rpc
        this.options = options
        this.protocolVersion = options.protocolVersion
    }

    public func discover(): DiscoverResult {
        DiscoverResult.fromJson(rpcCall('server/discover', None).asObject())
    }

    public func listTools(cursor!: ?String = None): ToolPage {
        ToolPage.fromJson(rpcCall('tools/list', cursorParams(cursor)).asObject())
    }

    public func listAllTools(): Array<McpToolDescriptor> {
        let all = ArrayList<McpToolDescriptor>()
        var cursor: ?String = None
        var rounds = 0
        while (rounds < 100 && all.size < 1000) {
            let page = listTools(cursor: cursor)
            for (tool in page.tools) {
                all.add(tool)
            }
            cursor = page.nextCursor
            if (cursor.isNone()) {
                break
            }
            rounds++
        }
        if (cursor.isSome()) {
            throw McpException(McpProtocol.INTERNAL_ERROR, 'tools/list pagination exceeded 100 pages')
        }
        all.toArray()
    }

    public func callTool(name: String, arguments!: JsonValue = JsonObject()): McpCallToolResult {
        let params = JsonObject()
        params.add('name', name)
        params.add('arguments', arguments)
        CallToolResult.fromJson(rpcCall('tools/call', params).asObject())
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
            let result = CallToolResult.fromJson(rpcCall('tools/call', params).asObject())
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

    public func listResources(cursor!: ?String = None): ResourcePage {
        ResourcePage.fromJson(rpcCall('resources/list', cursorParams(cursor)).asObject())
    }

    public func readResource(uri: String): ReadResourceResult {
        let params = JsonObject()
        params.add('uri', uri)
        ReadResourceResult.fromJson(rpcCall('resources/read', params).asObject())
    }

    public func listPrompts(cursor!: ?String = None): PromptPage {
        PromptPage.fromJson(rpcCall('prompts/list', cursorParams(cursor)).asObject())
    }

    /** 注册订阅；返回结果里的 `sseUrl` 可直接用于建立 SSE 连接。 */
    public func listen(topics: Array<String>): ListenResult {
        let params = JsonObject()
        let array = JsonArray()
        for (topic in topics) {
            array.add(topic)
        }
        params.add('topics', array)
        ListenResult.fromJson(rpcCall('subscriptions/listen', params).asObject())
    }

    public func getPrompt(name: String, arguments!: JsonObject = JsonObject()): GetPromptResult {
        let params = JsonObject()
        params.add('name', name)
        params.add('arguments', arguments)
        GetPromptResult.fromJson(rpcCall('prompts/get', params).asObject())
    }

    public func close(): Unit {
        rpc.close()
    }

    private func cursorParams(cursor: ?String): JsonObject {
        let params = JsonObject()
        match (cursor) {
            case Some(value) => params.add('cursor', value)
            case _ => ()
        }
        params
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
     * 协商新版本。
     *
     * 只有「当前版本还等于本次请求使用的版本」并且「目标版本确实不同」时才改写：
     * 并发命中 `-32022` 的请求不会各自覆盖一遍；服务端继续拒绝已协商的版本时
     * 也不会反复写同一个值、反复刷 INFO 日志。
     */
    private func negotiate(usedVersion: String, error: JsonRpcException): Unit {
        let next = supportedVersionOf(error)
        synchronized(versionMutex) {
            if (protocolVersion != usedVersion) {
                return
            }
            if (protocolVersion == next) {
                return
            }
            protocolVersion = next
            versionRewrites++
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
}
