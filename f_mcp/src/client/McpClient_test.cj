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

import std.collection.ArrayList
import std.net.{IPSocketAddress, TcpServerSocket, TcpSocket}
import std.sync.{AtomicInt64, Mutex}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_mcp.base.*

/**
 * 原始 TCP 上的最小 MCP 端点：记录请求头原文，响应完全由用例决定。
 *
 * 用来验证 `McpClientOptions` 真的透传到每个 HTTP 请求（真实 `HttpJsonRpcTransport`），
 * 而不是只验证选项映射。
 */
class RawMcpServer {
    let listener: TcpServerSocket
    let port: UInt16
    let accepted = AtomicInt64(0)
    private let requestHeads = ArrayList<String>()
    private let mutex = Mutex()

    init(handler: (TcpSocket) -> Unit) {
        let l = TcpServerSocket(bindAt: 0)
        l.bind()
        var p: UInt16 = 0
        match (l.localAddress) {
            case a: IPSocketAddress => p = a.port
            case _ => ()
        }
        this.listener = l
        this.port = p
        let heads = requestHeads
        let guard = mutex
        let counter = accepted
        spawn {
            while (true) {
                let sock = try {
                    l.accept()
                } catch (_: Exception) {
                    break
                }
                counter.fetchAdd(1)
                spawn {
                    try {
                        match (readRequestHead(sock)) {
                            case Some(head) => synchronized(guard) {
                                    heads.add(head)
                                }
                            case _ => ()
                        }
                        handler(sock)
                    } catch (_: Exception) {
                        ()
                    }
                    try {
                        sock.close()
                    } catch (_: Exception) {
                        ()
                    }
                }
            }
        }
    }

    prop url: String {
        get() {
            'http://127.0.0.1:${port}/mcp'
        }
    }

    prop requestCount: Int64 {
        get() {
            synchronized(mutex) {
                requestHeads.size
            }
        }
    }

    func requestAt(index: Int64): String {
        synchronized(mutex) {
            requestHeads[index]
        }
    }

    func close(): Unit {
        try {
            listener.close()
        } catch (_: Exception) {
            ()
        }
    }
}

private func readRequestHead(sock: TcpSocket): ?String {
    let buffer = Array<Byte>(1024, repeat: 0)
    let data = ArrayList<Byte>()
    while (data.size < 65536) {
        let n = try {
            sock.read(buffer)
        } catch (_: Exception) {
            -1
        }
        if (n <= 0) {
            return None<String>
        }
        data.add(all: buffer[0..n])
        let text = String.fromUtf8(data.toArray())
        if (text.contains('\r\n\r\n')) {
            return Some(text)
        }
    }
    None<String>
}

private func writeText(sock: TcpSocket, text: String): Bool {
    try {
        sock.write(text.unsafeBytes())
        true
    } catch (_: Exception) {
        false
    }
}

/** 始终 `Connection: close`：每个请求一条连接，便于统计。 */
private func jsonRpcReply(body: String): String {
    'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n' +
        'Content-Length: ${body.unsafeBytes().size}\r\nConnection: close\r\n\r\n${body}'
}

private func emptyToolsReply(): String {
    jsonRpcReply('{"jsonrpc":"2.0","id":1,"result":{"tools":[],"resultType":"complete"}}')
}

class FakeMcpRpc <: McpRpc {
    let requests = ArrayList<JsonObject>()
    private let handler: (String, ?JsonValue) -> JsonValue

    init(handler: (String, ?JsonValue) -> JsonValue) {
        this.handler = handler
    }

    public func call(method: String, params: ?JsonValue): JsonValue {
        let record = JsonObject()
        record.add('method', method)
        match (params) {
            case Some(value) => record.add('params', value)
            case _ => ()
        }
        requests.add(record)
        handler(method, params)
    }

    public func close(): Unit {}
}

class VersionRetryHandler {
    var calls = 0
    let payload: JsonValue

    init(payload: JsonValue) {
        this.payload = payload
    }

    func handle(method: String, params: ?JsonValue): JsonValue {
        calls++
        if (calls == 1) {
            let data = JsonObject()
            let supported = JsonArray()
            supported.add('2026-07-28-next')
            data.add('supported', supported)
            throw McpException(McpProtocol.UNSUPPORTED_VERSION, 'retry', data: data)
        }
        payload
    }
}

class AutoToolHandler {
    var calls = 0

    func handle(method: String, params: ?JsonValue): JsonValue {
        calls++
        let result = JsonObject()
        result.add('resultType', if (calls == 1) { 'input_required' } else { 'complete' })
        let content = JsonArray()
        content.add(ContentBlock.text('round${calls}').toJson())
        result.add('content', content)
        if (calls == 1) {
            let required = JsonObject()
            required.add('prompt', 'confirm?')
            result.add('inputRequired', required)
            let state = JsonObject()
            state.add('cursor', 7)
            result.add('requestState', state)
        }
        result
    }
}

class AlwaysInputHandler {
    func handle(method: String, params: ?JsonValue): JsonValue {
        let result = JsonObject()
        result.add('resultType', 'input_required')
        result.add('content', JsonArray())
        result.add('inputRequired', JsonObject())
        result
    }
}

/** 永远返回 `-32022`：用于并发协商用例（计数与请求列表都要线程安全）。 */
class AlwaysUnsupportedRpc <: McpRpc {
    private let mutex = Mutex()
    private var callCount = 0

    prop calls: Int64 {
        get() {
            synchronized(mutex) {
                callCount
            }
        }
    }

    public func call(method: String, params: ?JsonValue): JsonValue {
        synchronized(mutex) {
            callCount++
        }
        let data = JsonObject()
        let supported = JsonArray()
        supported.add('2026-07-28-next')
        data.add('supported', supported)
        throw McpException(McpProtocol.UNSUPPORTED_VERSION, 'retry', data: data)
    }

    public func close(): Unit {}
}

@Test
class McpClient_test {
    static func options(): McpClientOptions {
        McpClientOptions()
    }

    @TestCase
    public func testOptionsMapToJsonRpcOptions(): Unit {
        let options = McpClientOptions()
        options.timeout = Duration.second * 7
        options.maxResponseBytes = 1234
        options.keepAlive = false
        options.retryOnConnectFailure = 2
        options.headers.add('Authorization', 'Bearer x')
        let mapped = options.toJsonRpcOptions()
        @Assert(Duration.second * 7, mapped.timeout)
        @Assert(1234, mapped.maxResponseBytes)
        @Assert(false, mapped.keepAlive)
        @Assert(2, mapped.retryOnConnectFailure)
        @Assert('Bearer x', mapped.headers.get('Authorization').getOrThrow())
    }

    @TestCase
    public func testNonVersionErrorIsNotRetried(): Unit {
        let calls = AtomicInt64(0)
        let rpc = FakeMcpRpc({_, _ =>
            calls.fetchAdd(1)
            throw McpException(McpProtocol.INVALID_PARAMS, 'bad')
        })
        let client = McpClient(rpc, options())
        try {
            client.listTools()
            @Fail('expected McpException')
        } catch (e: McpException) {
            @Assert(McpProtocol.INVALID_PARAMS, e.code)
        }
        @Assert(1, calls.load())
    }

    @TestCase
    public func testMetaInjectedOnEveryRequest(): Unit {
        let rpc = FakeMcpRpc({_, _ => JsonObject()})
        let client = McpClient(rpc, options())
        let _ = client.listTools()
        let request = rpc.requests[0]
        let meta = request['params'].asObject()['_meta'].asObject()
        @Assert(McpProtocol.VERSION,
            meta[McpProtocol.KEY_PROTOCOL_VERSION].asString().value)
        @Assert(true, meta.contains(McpProtocol.KEY_CLIENT_INFO))
        @Assert(true, meta.contains(McpProtocol.KEY_CLIENT_CAPABILITIES))
    }

    @TestCase
    public func testVersionRetryOnce(): Unit {
        let payload = JsonObject()
        payload.add('tools', JsonArray())
        let handler = VersionRetryHandler(payload)
        let rpc = FakeMcpRpc({method, params => handler.handle(method, params)})
        let client = McpClient(rpc, options())
        let result = client.listTools()
        @Assert(2, handler.calls)
        @Assert(0, result.tools.size)
        let second = rpc.requests[1]['params'].asObject()['_meta'].asObject()
        @Assert('2026-07-28-next', second[McpProtocol.KEY_PROTOCOL_VERSION].asString().value)
    }

    @TestCase
    public func testListAllTools(): Unit {
        let rpc = FakeMcpRpc({_, params =>
            let result = JsonObject()
            let tools = JsonArray()
            let page = match (params) {
                case Some(obj: JsonObject) => if (obj.contains('cursor')) { 2 } else { 1 }
                case _ => 1
            }
            let tool = JsonObject()
            tool.add('name', 't${page}')
            tools.add(tool)
            result.add('tools', tools)
            if (page == 1) {
                result.add('nextCursor', McpProtocol.encodeCursor(1))
            }
            result
        })
        let client = McpClient(rpc, options())
        let all = client.listAllTools()
        @Assert(2, all.size)
        @Assert('t1', all[0].name)
        @Assert('t2', all[1].name)
    }

    @TestCase
    public func testDiscoverReturnsStrongTypes(): Unit {
        let rpc = FakeMcpRpc({_, _ =>
            let result = JsonObject()
            let versions = JsonArray()
            versions.add(McpProtocol.VERSION)
            result.add('supportedVersions', versions)
            let caps = JsonObject()
            let resources = JsonObject()
            resources.add('subscribe', false)
            resources.add('listChanged', false)
            caps.add('resources', resources)
            let tools = JsonObject()
            tools.add('listChanged', false)
            caps.add('tools', tools)
            result.add('capabilities', caps)
            let meta = JsonObject()
            let info = JsonObject()
            info.add('name', 'demo')
            info.add('version', '9.9.9')
            meta.add(McpProtocol.KEY_SERVER_INFO, info)
            result.add(McpProtocol.META, meta)
            result
        })
        let client = McpClient(rpc, options())
        let discover = client.discover()
        @Assert(1, discover.supportedVersions.size)
        @Assert(McpProtocol.VERSION, discover.supportedVersions[0])
        @Assert(false, discover.capabilities.resourcesSubscribe)
        @Assert(false, discover.capabilities.toolsListChanged)
        @Assert('demo', discover.serverInfo.getOrThrow().name)
        @Assert('9.9.9', discover.serverInfo.getOrThrow().version)
    }

    @TestCase
    public func testListToolsReturnsDescriptors(): Unit {
        let rpc = FakeMcpRpc({_, _ =>
            let result = JsonObject()
            let tools = JsonArray()
            let tool = JsonObject()
            tool.add('name', 'echo')
            tool.add('description', 'echo text')
            let schema = JsonObject()
            schema.add('type', 'object')
            tool.add('inputSchema', schema)
            tools.add(tool)
            result.add('tools', tools)
            result
        })
        let client = McpClient(rpc, options())
        let page = client.listTools()
        @Assert(1, page.tools.size)
        @Assert('echo', page.tools[0].name)
        @Assert('object', page.tools[0].inputSchema['type'].asString().value)
        @Assert(true, page.nextCursor.isNone())
    }

    @TestCase
    public func testReadResourceAndGetPromptStrongTypes(): Unit {
        let rpc = FakeMcpRpc({method, _ =>
            let result = JsonObject()
            if (method == 'resources/read') {
                let contents = JsonArray()
                let item = JsonObject()
                item.add('uri', 'file:///a.txt')
                item.add('mimeType', 'text/plain')
                item.add('text', 'hello')
                contents.add(item)
                result.add('contents', contents)
            } else {
                result.add('description', 'greet')
                let messages = JsonArray()
                let message = JsonObject()
                message.add('role', 'user')
                message.add('content', ContentBlock.text('hi').toJson())
                messages.add(message)
                result.add('messages', messages)
            }
            result
        })
        let client = McpClient(rpc, options())
        let resource = client.readResource('file:///a.txt')
        @Assert(1, resource.contents.size)
        @Assert('hello', resource.contents[0].text.getOrThrow())
        @Assert('text/plain', resource.contents[0].mimeType.getOrThrow())
        let prompt = client.getPrompt('greet')
        @Assert('greet', prompt.description)
        @Assert(1, prompt.messages.size)
        @Assert('user', prompt.messages[0].role)
        @Assert('text', prompt.messages[0].content.kind())
    }

    @TestCase
    public func testListenReturnsStrongTypes(): Unit {
        let rpc = FakeMcpRpc({_, _ =>
            let result = JsonObject()
            result.add('subscriptionId', 42)
            let topics = JsonArray()
            topics.add('tools/list_changed')
            result.add('subscribedTopics', topics)
            result.add('sseUrl', '/mcp/sse?subscriptionId=42')
            result
        })
        let client = McpClient(rpc, options())
        let listen = client.listen(['tools/list_changed'])
        @Assert(42, listen.subscriptionId)
        @Assert(1, listen.subscribedTopics.size)
        @Assert('/mcp/sse?subscriptionId=42', listen.sseUrl)
    }

    @TestCase
    public func testAutoRoundsComplete(): Unit {
        let handler = AutoToolHandler()
        let rpc = FakeMcpRpc({method, params => handler.handle(method, params)})
        let client = McpClient(rpc, options())
        let result = client.callToolAuto('tool', handler: {input => JsonObject()}, maxRounds: 3)
        @Assert('complete', result.resultType)
        @Assert(2, handler.calls)
        @Assert(2, rpc.requests.size)
        let secondParams = rpc.requests[1]['params'].asObject()
        @Assert(true, secondParams.contains('inputResponses'))
        @Assert(true, secondParams.contains('arguments'))
    }

    @TestCase
    public func testAutoRoundsForwardRequestState(): Unit {
        let handler = AutoToolHandler()
        let rpc = FakeMcpRpc({method, params => handler.handle(method, params)})
        let client = McpClient(rpc, options())
        let result = client.callToolAuto('tool', handler: {input => JsonObject()}, maxRounds: 3)
        @Assert('complete', result.resultType)
        let firstParams = rpc.requests[0]['params'].asObject()
        @Assert(false, firstParams.contains('requestState'))
        let secondParams = rpc.requests[1]['params'].asObject()
        @Assert(7, secondParams['requestState'].asObject()['cursor'].asInt().toInt64())
        @Assert(true, secondParams.contains('inputResponses'))
    }

    @TestCase
    public func testCallToolParsesRequestState(): Unit {
        let rpc = FakeMcpRpc({_, _ =>
            let result = JsonObject()
            result.add('content', JsonArray())
            result.add('requestState', JsonString('st-1'))
            result
        })
        let client = McpClient(rpc, options())
        let result = client.callTool('tool')
        @Assert('st-1', result.requestState.getOrThrow().asString().value)
    }

    @TestCase
    public func testAutoRoundsExceeded(): Unit {
        let handler = AlwaysInputHandler()
        let rpc = FakeMcpRpc({method, params => handler.handle(method, params)})
        let client = McpClient(rpc, options())
        try {
            client.callToolAuto('tool', handler: {input => JsonObject()}, maxRounds: 2)
            @Fail('expected McpException')
        } catch (e: McpException) {
            @Assert(true, e.message.contains('requires input'))
        }
    }

    /** 每个 HTTP 请求都带 `McpClientOptions.headers`。 */
    @TestCase
    public func testHeadersAreSentOnEveryRequest(): Unit {
        let server = RawMcpServer({sock => writeText(sock, emptyToolsReply())})
        let options = McpClientOptions()
        options.headers.add('Authorization', 'Bearer x')
        let client = McpClient(server.url, options: options)
        try {
            let _ = client.listTools()
            let _ = client.listTools()
            @Assert(2, server.requestCount)
            @Assert(true, server.requestAt(0).toAsciiLower().contains('authorization: bearer x'))
            @Assert(true, server.requestAt(1).toAsciiLower().contains('authorization: bearer x'))
        } finally {
            client.close()
            server.close()
        }
    }

    /** `maxResponseBytes` 透传到传输层：超过上限抛错，而不是读完整个 body。 */
    @TestCase
    public func testMaxResponseBytesFromOptions(): Unit {
        let padding = String.fromUtf8(Array<Byte>(8192, repeat: 120))
        let server = RawMcpServer({sock =>
            writeText(sock, jsonRpcReply('{"jsonrpc":"2.0","id":1,"result":{"tools":[],"pad":"${padding}"}}'))
        })
        let options = McpClientOptions()
        options.maxResponseBytes = 1024
        let client = McpClient(server.url, options: options)
        try {
            client.listTools()
            @Fail('expected McpException')
        } catch (e: McpException) {
            @Assert(McpProtocol.INTERNAL_ERROR, e.code)
            @Assert(true, e.message.contains('exceeds'))
        } finally {
            client.close()
            server.close()
        }
    }

    /** `keepAlive = false` 时每个请求带 `Connection: close`；默认不带。 */
    @TestCase
    public func testKeepAliveMapsToConnectionHeader(): Unit {
        let closing = RawMcpServer({sock => writeText(sock, emptyToolsReply())})
        let closeOptions = McpClientOptions()
        closeOptions.keepAlive = false
        let closeClient = McpClient(closing.url, options: closeOptions)
        try {
            let _ = closeClient.listTools()
            @Assert(true, closing.requestAt(0).toAsciiLower().contains('connection: close'))
        } finally {
            closeClient.close()
            closing.close()
        }

        let reusing = RawMcpServer({sock => writeText(sock, emptyToolsReply())})
        let reuseClient = McpClient(reusing.url, options: McpClientOptions())
        try {
            let _ = reuseClient.listTools()
            @Assert(false, reusing.requestAt(0).toAsciiLower().contains('connection: close'))
        } finally {
            reuseClient.close()
            reusing.close()
        }
    }

    /** `retryOnConnectFailure = 2` 透传：建连/发送失败重试，总尝试 3 次。 */
    @TestCase
    public func testRetryOnConnectFailureFromOptions(): Unit {
        let server = RawMcpServer({_ => ()}) // 立刻关闭连接：发送阶段失败
        let options = McpClientOptions()
        options.retryOnConnectFailure = 2
        let client = McpClient(server.url, options: options)
        var failed = false
        try {
            client.listTools()
        } catch (_: McpException) {
            failed = true
        } finally {
            sleep(Duration.millisecond * 200)
            client.close()
            server.close()
        }
        @Assert(true, failed)
        @Assert(3, server.accepted.load())
    }

    /** 8 线程同时命中 `-32022`：版本只改写一次，每个请求最多重试一次。 */
    @TestCase
    public func testConcurrentVersionNegotiationRewritesOnce(): Unit {
        let rpc = AlwaysUnsupportedRpc()
        let client = McpClient(rpc, options())
        let futures = ArrayList<Future<Unit>>()
        for (_ in 0..8) {
            futures.add(
                spawn {
                    try {
                        let _ = client.listTools()
                    } catch (_: McpException) {
                        ()
                    }
                }
            )
        }
        for (future in futures) {
            future.get()
        }
        @Assert(1, client.versionRewrites)
        @Assert(16, rpc.calls)
    }

    @TestCase
    public func testManualPassthrough(): Unit {
        let handler = AlwaysInputHandler()
        let rpc = FakeMcpRpc({method, params => handler.handle(method, params)})
        let client = McpClient(rpc, options())
        let result = client.callTool('tool')
        @Assert('input_required', result.resultType)
        @Assert(true, result.inputRequired.isSome())
    }
}
