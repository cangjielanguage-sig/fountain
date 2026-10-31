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
import std.net.{IPSocketAddress, TcpServerSocket, TcpSocket}
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*
import fountain::f_data.*
import fountain::f_jsonrpc.server.JsonRpcContext
import fountain::f_mcp.base.*

/**
 * `/mcp` 的 HTTP 行为（429 / caller 派生）需要真实请求上下文：
 * `HttpContext` 无法在测试里构造，因此起一个最小 stdx 服务，
 * 把请求体原样交给 `McpServer.jsonRpcServer().handle`（与 `McpController.handle` 等价）。
 */
private class McpHttpHandler <: HttpRequestHandler {
    private let server: McpServer

    McpHttpHandler(server: McpServer) {
        this.server = server
    }

    public func handle(ctx: HttpContext): Unit {
        let out = ArrayList<Byte>()
        let buf = Array<Byte>(4096, repeat: 0)
        while (true) {
            let n = try {
                ctx.request.body.read(buf)
            } catch (_: Exception) {
                -1
            }
            if (n <= 0) {
                break
            }
            out.add(all: buf[0..n])
        }
        let body = out.unsafeData()
        match (server.jsonRpcServer().handle(body,
            ctx: JsonRpcContext(http: Some(ctx), endpoint: McpProtocol.PATH))) {
            case Some(value) => ctx.responseBuilder.body(value.toString())
            case _ => ()
        }
    }
}

private class McpAnyPathDistributor <: HttpRequestDistributor {
    private let handler: HttpRequestHandler

    McpAnyPathDistributor(handler: HttpRequestHandler) {
        this.handler = handler
    }

    public func register(path: String, handler: HttpRequestHandler): Unit {}

    public func register(path: String, handler: (HttpContext) -> Unit): Unit {}

    public func distribute(path: String): HttpRequestHandler {
        handler
    }
}

private func mcpFreePort(): UInt16 {
    let probe = TcpServerSocket(bindAt: 0)
    probe.bind()
    var port: UInt16 = 0
    match (probe.localAddress) {
        case addr: IPSocketAddress => port = addr.port
        case _ => ()
    }
    probe.close()
    port
}

private func startMcpHttp(server: McpServer): (UInt16, Server) {
    let port = mcpFreePort()
    let http = ServerBuilder()
        .addr('127.0.0.1')
        .port(port)
        .distributor(McpAnyPathDistributor(McpHttpHandler(server)))
        .build()
    spawn {
        http.serve()
    }
    for (_ in 0..50) {
        try {
            let probe = TcpSocket('127.0.0.1', port)
            probe.connect()
            probe.close()
            break
        } catch (_: Exception) {
            sleep(Duration.millisecond * 100)
        }
    }
    (port, http)
}

/** 发原始请求并读完整响应（请求带头 `Connection: close`）。 */
private func mcpRequest(port: UInt16, headers: String, body: String): String {
    let socket = TcpSocket('127.0.0.1', port)
    socket.connect()
    let request = 'POST ${McpProtocol.PATH} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n' +
        'Content-Type: application/json\r\nContent-Length: ${body.unsafeBytes().size}\r\n' + headers +
        'Connection: close\r\n\r\n' + body
    socket.write(request.unsafeBytes())
    let out = ArrayList<Byte>()
    let buf = Array<Byte>(4096, repeat: 0)
    while (true) {
        let n = try {
            socket.read(buf)
        } catch (_: Exception) {
            0
        }
        if (n <= 0) {
            break
        }
        out.add(all: buf[0..n])
    }
    socket.close()
    String.fromUtf8(out.unsafeData())
}

private func statusLineOf(response: String): String {
    match (response.indexOf('\r\n')) {
        case Some(index) => response[0..index]
        case _ => response
    }
}

private func headerOf(response: String, name: String): ?String {
    let prefix = '${name.toAsciiLower()}:'
    for (line in response.split('\r\n')) {
        if (line.toAsciiLower().startsWith(prefix)) {
            return Some(line[name.size + 1..].trimAscii())
        }
    }
    None<String>
}

private func bodyOf(response: String): String {
    match (response.indexOf('\r\n\r\n')) {
        case Some(index) => response[index + 4..]
        case _ => ''
    }
}

private func callerTool(): McpTool {
    McpTool.builder('who').description('echo caller')
        .handler({ctx, _ => CallToolResult.text(ctx.callerId)}).build()
}

private func pingTool(): McpTool {
    McpTool.builder('ping').handler({_, _ => CallToolResult.text('pong')}).build()
}

private func toolCallBody(name: String, version!: String = McpProtocol.VERSION): String {
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"${McpProtocol.META}":' +
        '{"${McpProtocol.KEY_PROTOCOL_VERSION}":"${version}"},' + '"name":"${name}","arguments":{}}}'
}

private func errorOf(response: String): JsonObject {
    JsonValue.fromStr(bodyOf(response)).asObject()['error'].asObject()
}

private func codeOf(response: String): Int64 {
    errorOf(response)['code'].asInt().toInt64()
}

@Test
class McpHttp_test {
    /** 限流拒绝的 HTTP 响应状态必须 429，并带 `Retry-After >= 1`。 */
    @TestCase
    public func testRateLimitReturns429AndRetryAfter(): Unit {
        let server = McpServer.builder()
            .rateLimit(RateLimitPolicy(perCallerRpm: 1))
            .tool(McpTool.builder('ping').handler({_, _ => CallToolResult.text('pong')}).build())
            .build()
        let (port, http) = startMcpHttp(server)
        try {
            let first = mcpRequest(port, '', toolCallBody('ping'))
            @Assert(true, statusLineOf(first).contains('200'))
            let second = mcpRequest(port, '', toolCallBody('ping'))
            @Assert(true, statusLineOf(second).contains('429'))
            let retryAfter = headerOf(second, 'Retry-After').getOrThrow()
            @Assert(true, Int64.parse(retryAfter) >= 1)
            let error = JsonValue.fromStr(bodyOf(second)).asObject()['error'].asObject()
            @Assert(McpProtocol.RATE_LIMITED, error['code'].asInt().toInt64())
        } finally {
            http.closeGracefully()
        }
    }

    /** 显式信任代理时，caller 取 `X-Forwarded-For` 第一段。 */
    @TestCase
    public func testTrustedForwardedForBecomesCaller(): Unit {
        let server = McpServer.builder().trustForwardedFor(true).tool(callerTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'X-Forwarded-For: 1.2.3.4, 10.0.0.1\r\n', toolCallBody('who'))
            @Assert('1.2.3.4', callerOf(response))
        } finally {
            http.closeGracefully()
        }
    }

    /** 默认不信任 `X-Forwarded-For`：caller 仍是 `remoteAddr`（去掉端口）。 */
    @TestCase
    public func testUntrustedForwardedForIsIgnored(): Unit {
        let server = McpServer.builder().tool(callerTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'X-Forwarded-For: 1.2.3.4\r\n', toolCallBody('who'))
            @Assert('127.0.0.1', callerOf(response))
        } finally {
            http.closeGracefully()
        }
    }

    /** `Authorization` 的 caller 是 SHA-256 前 16 字节的 32 位十六进制。 */
    @TestCase
    public func testAuthorizationDerivesHashedCaller(): Unit {
        let server = McpServer.builder().tool(callerTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'Authorization: Bearer secret\r\n', toolCallBody('who'))
            let caller = callerOf(response)
            @Assert(32, caller.size)
            for (c in caller.toRuneArray()) {
                let hex = (c >= r'0' && c <= r'9') || (c >= r'a' && c <= r'f')
                @Assert(true, hex)
            }
        } finally {
            http.closeGracefully()
        }
    }

    /** 头与 body 不一致优先 `-32602`，`data.header` / `data.body` 为原值。 */
    @TestCase
    public func testHeaderBodyVersionMismatchIsInvalidParams(): Unit {
        let server = McpServer.builder().tool(pingTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'MCP-Protocol-Version: ${McpProtocol.VERSION}\r\n',
                toolCallBody('ping', version: '2025-11-25'))
            @Assert(McpProtocol.INVALID_PARAMS, codeOf(response))
            let data = errorOf(response)['data'].asObject()
            @Assert(McpProtocol.VERSION, data['header'].asString().value)
            @Assert('2025-11-25', data['body'].asString().value)
        } finally {
            http.closeGracefully()
        }
    }

    /** 头版本不受支持 → `-32022`，与 body 是否合法无关。 */
    @TestCase
    public func testUnsupportedHeaderVersionIsRejected(): Unit {
        let server = McpServer.builder().tool(pingTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'MCP-Protocol-Version: 1900-01-01\r\n', toolCallBody('ping'))
            @Assert(McpProtocol.UNSUPPORTED_VERSION, codeOf(response))
            @Assert('1900-01-01', errorOf(response)['data'].asObject()['requested'].asString().value)
        } finally {
            http.closeGracefully()
        }
    }

    /** 头与 body 都不受支持时，先报头（校验顺序：头受支持性优先于一致性）。 */
    @TestCase
    public func testUnsupportedHeaderWinsOverMismatch(): Unit {
        let server = McpServer.builder().tool(pingTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let response = mcpRequest(port, 'MCP-Protocol-Version: 1900-01-01\r\n',
                toolCallBody('ping', version: '2025-11-25'))
            @Assert(McpProtocol.UNSUPPORTED_VERSION, codeOf(response))
            @Assert('1900-01-01', errorOf(response)['data'].asObject()['requested'].asString().value)
        } finally {
            http.closeGracefully()
        }
    }

    /** 头缺失：只按 body 校验——body 合法受理，body 非法 `-32022`。 */
    @TestCase
    public func testMissingHeaderFallsBackToBody(): Unit {
        let server = McpServer.builder().tool(pingTool()).build()
        let (port, http) = startMcpHttp(server)
        try {
            let accepted = mcpRequest(port, '', toolCallBody('ping'))
            @Assert(true, statusLineOf(accepted).contains('200'))
            let rejected = mcpRequest(port, '', toolCallBody('ping', version: '2025-11-25'))
            @Assert(McpProtocol.UNSUPPORTED_VERSION, codeOf(rejected))
            @Assert('2025-11-25', errorOf(rejected)['data'].asObject()['requested'].asString().value)
        } finally {
            http.closeGracefully()
        }
    }

    private func callerOf(response: String): String {
        let result = JsonValue.fromStr(bodyOf(response)).asObject()['result'].asObject()
        result['content'].asArray()[0].asObject()['text'].asString().value
    }
}
