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
package fountain::mcpclient

import std.collection.ArrayList
import std.env.{exit, getVariable}
import stdx.net.http.*
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_data.*
import fountain::f_mcp.*

private func fail(message: String): Unit {
    println('MCP_DEMO_FAILED ${message}')
    exit(1)
}

private func textOf(result: McpCallToolResult): String {
    if (result.content.size == 0) {
        return ''
    }
    match (result.content[0].toJson().get('text')) {
        case Some(value) => value.asString().value
        case _ => ''
    }
}

private func verifyTools(client: McpClient): Unit {
    let tools = client.listAllTools()
    let names = ArrayList<String>()
    for (tool in tools) {
        names.add(tool.name)
    }
    for (name in ['echo', 'notify', 'limited']) {
        if (!names.contains(name)) {
            fail('tool not listed: ${name}')
        }
    }
}

private func verifyResourceAndPrompt(client: McpClient, baseUrl: String): Unit {
    let resource = client.readResource('${baseUrl}/greeting')
    if (resource.contents.size != 1 ||
        !resource.contents[0].text.getOrThrow().startsWith('hello ')) {
        fail('unexpected resource contents')
    }

    let args = JsonObject()
    args.add('name', 'mcp')
    let prompt = client.getPrompt('greet', arguments: args)
    if (prompt.messages.size != 1 || prompt.messages[0].role != 'user') {
        fail('unexpected prompt messages')
    }
}

private func verifySse(url: String, baseUrl: String): Unit {
    let listener = McpClient.http(url)
    let subscription = try {
        listener.listen(['tools/list_changed'])
    } finally {
        listener.close()
    }
    let ssePath = subscription.sseUrl
    let sseUrl = if (ssePath.startsWith('http://') || ssePath.startsWith('https://')) {
        ssePath
    } else {
        '${baseUrl}${ssePath}'
    }
    let sseClient = ClientBuilder().readTimeout(Duration.second * 15).build()
    let future = spawn {
        sseClient.send(
            HttpRequestBuilder()
                .method('GET')
                .url(sseUrl)
                .header('Accept', 'text/event-stream')
                .build())
    }
    sleep(Duration.millisecond * 800)
    let notifier = McpClient.http(url)
    try {
        let result = notifier.callTool('notify', arguments: JsonObject())
        if (textOf(result) != 'published') {
            fail('notify tool did not publish')
        }
    } finally {
        notifier.close()
    }

    let response = future.get()
    let buffer = Array<Byte>(4096, repeat: 0)
    var text = ''
    let deadline = MonoTime.now() + Duration.second * 15
    while (!text.contains('notifications/tools/list_changed') && MonoTime.now() < deadline) {
        let size = response.body.read(buffer)
        if (size <= 0) {
            break
        }
        text += String.fromUtf8(buffer[0..size])
    }
    response.close()
    sseClient.close()
    if (!text.contains('event: message') || !text.contains('notifications/tools/list_changed')) {
        fail('no SSE notification received; got: ${text}')
    }
}

private func runDemo(): Unit {
    let port = getVariable('mcp_demo_port') ?? '18082'
    let baseUrl = 'http://127.0.0.1:${port}'
    let client = McpClient.http('${baseUrl}/mcp')
    try {
        let discover = client.discover()
        match (discover.serverInfo) {
            case Some(info) => if (info.name != 'fmcpdemo') {
                fail('unexpected server name')
            }
            case _ => fail('missing server info')
        }

        verifyTools(client)
        let echoArgs = JsonObject()
        echoArgs.add('text', 'hello mcp')
        let echo = client.callTool('echo', arguments: echoArgs)
        if (textOf(echo) != 'echo:hello mcp') {
            fail('unexpected echo result: ${textOf(echo)}')
        }
        verifyResourceAndPrompt(client, baseUrl)
    } finally {
        client.close()
    }

    verifySse('${baseUrl}/mcp', baseUrl)
    println('MCP_HTTP_DEMO_OK discover tools/call resources/read prompts/get sse')
}

public struct McpDemoClient <: Initializer {
    static init() {
        InitializerCollection.register(McpDemoClient())
    }

    private init() {}

    public prop name: String {
        get() {
            'fmcpdemo::client'
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {
        try {
            runDemo()
            exit(0)
        } catch (e: Exception) {
            fail(e.message)
        }
    }
}
