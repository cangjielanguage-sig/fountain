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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_mcp.base.*

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

@Test
class McpClient_test {
    static func options(): McpClientOptions {
        McpClientOptions()
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
        @Assert(true, result.contains('tools'))
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
