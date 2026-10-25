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
package fountain::mcpserver

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64
import fountain::f_data.*
import fountain::f_data.macros.DataAssist
import fountain::f_jsonrpc.base.JsonRpcException
import fountain::f_mcp.*
import fountain::f_mcp.macros.*

/**
 * 演示「分布式」限流：计数器放在一个共享对象里，多个 McpServer 实例共同消耗同一份额度。
 *
 * 真实部署中把这里换成 Redis / f_store 等共享存储即可；接口不变。
 */
public class SharedWindowBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'shared-window'
        }
    }

    public static func new(): RateLimitBackend {
        SharedWindowBackend()
    }

    private let counters = ConcurrentHashMap<String, AtomicInt64>()

    public func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool {
        if (rpm <= 0) {
            return true
        }
        let window = nowNanos / 60_000_000_000
        let bucket = '${key}@${window}'
        var counter = counters.get(bucket)
        if (counter.isNone()) {
            counters.addIfAbsent(bucket, AtomicInt64(0))
            counter = counters.get(bucket)
        }
        let atomic = counter.getOrThrow()
        while (true) {
            let current = atomic.load()
            if (current >= rpm) {
                return false
            }
            if (atomic.compareAndSwap(current, current + 1)) {
                return true
            }
        }
        false
    }

    public func close(): Unit {
        for ((key, _) in counters) {
            counters.remove(key)
        }
    }
}

@DataAssist[props fields]
public class EchoRequest {
    public var text: String = ''

    public init() {}
}

@DataAssist[props fields]
public class EmptyRequest {
    public init() {}
}

/**
 * 演示用 MCP 服务：全部通过注解注册。
 *
 * - `@Mcp['fmcpdemo']`：`serverInfo.name`
 * - tool / resource / prompt 分别用 `@McpToolMeta` / `@McpResourceMeta` / `@McpPromptMeta`
 */
@Mcp['fmcpdemo']
public class McpDemoService {
    public init() {}

    @McpToolMeta[name: 'echo', description: '回显文本']
    public func echo(req: EchoRequest): CallToolResult {
        CallToolResult.text('echo:${req.text}')
    }

    @McpToolMeta[name: 'notify', description: '发布一条 tools/list_changed 通知']
    public func notify(req: EmptyRequest): CallToolResult {
        let params = JsonObject()
        params.add('reason', 'demo')
        McpRegistry.server().hub().publish('tools/list_changed', params)
        CallToolResult.text('published')
    }

    @McpToolMeta[name: 'limited', description: '每调用方每分钟 3 次', perCallerToolRpm: 3]
    public func limited(req: EmptyRequest): CallToolResult {
        CallToolResult.text('limited-ok')
    }

    @McpResourceMeta[uri: '/greeting', name: 'greeting', description: '演示资源', mediaType: 'text/plain']
    public func greeting(): String {
        'hello from fmcpdemo'
    }

    @McpPromptMeta[name: 'greet', description: '生成一句问候']
    public func greet(@McpPromptArg[description: '姓名', required: true] name: String): String {
        'hello ${name}'
    }
}

private func emptySchema(): JsonObject {
    let schema = JsonObject()
    schema.add('type', 'object')
    schema.add('properties', JsonObject())
    schema.add('additionalProperties', false)
    schema
}

private func limitedTool(): McpTool {
    McpTool
        .builder('limited')
        .description('每调用方每分钟 3 次')
        .inputSchema(emptySchema())
        .rateLimit(ToolRateLimit(perCallerToolRpm: 3))
        .handler({_, _ => CallToolResult.text('limited-ok')})
        .build()
}

private func toolCallParams(name: String): JsonObject {
    let params = JsonObject()
    params.add('name', name)
    params.add('arguments', JsonObject())
    let meta = JsonObject()
    meta.add(McpProtocol.KEY_PROTOCOL_VERSION, McpProtocol.VERSION)
    let info = JsonObject()
    info.add('name', 'limit-check')
    info.add('version', '1.0.0')
    meta.add(McpProtocol.KEY_CLIENT_INFO, info)
    meta.add(McpProtocol.KEY_CLIENT_CAPABILITIES, JsonObject())
    params.add(McpProtocol.META, meta)
    params
}

private func callCode(server: McpServer): Int64 {
    try {
        server.jsonRpcServer().invoke('tools/call', params: toolCallParams('limited'))
        -1
    } catch (e: JsonRpcException) {
        e.code
    }
}

/**
 * 两个 server 共用一个 backend：前 3 次通过，第 4 次必须 -32050。
 */
private func distributedLimitCheck(): String {
    let backend = SharedWindowBackend()
    let tool = limitedTool()
    let a = McpServer.builder().rateLimitBackend(backend).tool(tool).build()
    let b = McpServer.builder().rateLimitBackend(backend).tool(tool).build()
    let codes = ArrayList<Int64>()
    codes.add(callCode(a))
    codes.add(callCode(a))
    codes.add(callCode(b))
    codes.add(callCode(b))
    if (codes[0] != -1 || codes[1] != -1 || codes[2] != -1 || codes[3] != McpProtocol.RATE_LIMITED) {
        throw McpException(McpProtocol.INTERNAL_ERROR, 'distributed rate limit check failed: ${codes}')
    }
    'MCP_LIMIT_DEMO_OK shared_by_two_servers fourth_code=${codes[3]}'
}

private let _ = {
    =>
        println('MCP_SERVER_DEMO_READY tools=echo,notify,limited resource=greeting prompt=greet')
        println(distributedLimitCheck())
}()
