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
package fountain::f_mcp.base

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*

@Test
class McpModels_test {
    @TestCase
    public func testContentBlockRoundTrip(): Unit {
        let text = JsonValue.fromStr('{"type":"text","text":"hi"}').asObject()
        let textBlock = ContentBlock.fromJson(text)
        @Assert('text', textBlock.kind())
        @Assert('hi', textBlock.toJson()['text'].asString().value)

        let image = JsonValue.fromStr('{"type":"image","data":"aGk=","mimeType":"image/png"}').asObject()
        let imageBlock = ContentBlock.fromJson(image)
        @Assert('image', imageBlock.kind())
        @Assert('image/png', imageBlock.toJson()['mimeType'].asString().value)

        let audio = JsonValue.fromStr('{"type":"audio","data":"aGk=","mimeType":"audio/wav"}').asObject()
        @Assert('audio', ContentBlock.fromJson(audio).kind())

        let resource = JsonValue.fromStr('{"type":"resource","resource":{"uri":"file:///a","text":"t"}}').asObject()
        let resourceBlock = ContentBlock.fromJson(resource)
        @Assert('resource', resourceBlock.kind())
        @Assert('file:///a', resourceBlock.toJson()['resource'].asObject()['uri'].asString().value)

        let link = JsonValue.fromStr('{"type":"resource_link","uri":"file:///b","name":"b"}').asObject()
        let linkBlock = ContentBlock.fromJson(link)
        @Assert('resource_link', linkBlock.kind())
        @Assert('file:///b', linkBlock.toJson()['uri'].asString().value)
    }

    @TestCase
    public func testUnknownContentBlockIsPreserved(): Unit {
        let raw = JsonValue.fromStr('{"type":"vendor_custom","payload":{"n":1}}').asObject()
        let block = ContentBlock.fromJson(raw)
        @Assert('vendor_custom', block.kind())
        @Assert(1, block.toJson()['payload'].asObject()['n'].asInt().toInt64())
    }

    @TestCase
    public func testCallToolResultRoundTrip(): Unit {
        let raw = JsonValue.fromStr('{"content":[{"type":"text","text":"hi"},{"type":"vendor","x":1}],' +
            '"structuredContent":{"a":1},"isError":true,"resultType":"input_required",' +
            '"inputRequired":{"prompt":"confirm"},"requestState":{"cursor":7},' +
            '"data":{"truncated":true}}').asObject()
        let result = CallToolResult.fromJson(raw)
        @Assert(2, result.content.size)
        @Assert('text', result.content[0].kind())
        @Assert('vendor', result.content[1].kind())
        @Assert(true, result.isError)
        @Assert('input_required', result.resultType)
        @Assert('confirm', result.inputRequired.getOrThrow().asObject()['prompt'].asString().value)
        @Assert(7, result.requestState.getOrThrow().asObject()['cursor'].asInt().toInt64())
        @Assert(true, result.extra.getOrThrow()['truncated'].asBool().value)
        let restored = result.toJson()
        @Assert(2, restored['content'].asArray().size)
        @Assert('input_required', restored['resultType'].asString().value)
        @Assert(7, restored['requestState'].asObject()['cursor'].asInt().toInt64())
        @Assert(true, restored['data'].asObject()['truncated'].asBool().value)
    }

    @TestCase
    public func testCapabilitiesKeepUnknownFields(): Unit {
        let raw = JsonValue.fromStr('{"tools":{"listChanged":false,"foo":true},' +
            '"resources":{"subscribe":false,"listChanged":false},"prompts":{"listChanged":false}}').asObject()
        let caps = McpCapabilities.fromJson(raw)
        @Assert(false, caps.toolsListChanged)
        @Assert(false, caps.resourcesSubscribe)
        @Assert(false, caps.promptsListChanged)
        @Assert(true, caps.toJson()['tools'].asObject()['foo'].asBool().value)
    }

    @TestCase
    public func testDiscoverResultFromJson(): Unit {
        let raw = JsonValue.fromStr('{"supportedVersions":["2026-07-28"],"capabilities":{},"_meta":' +
            '{"io.modelcontextprotocol/serverInfo":{"name":"srv","version":"1.0.0"}}}').asObject()
        let result = DiscoverResult.fromJson(raw)
        @Assert(1, result.supportedVersions.size)
        @Assert('srv', result.serverInfo.getOrThrow().name)
    }

    @TestCase
    public func testPromptArgumentRoundTrip(): Unit {
        let raw = JsonValue.fromStr('{"name":"topic","description":"d","required":true}').asObject()
        let arg = PromptArgument.fromJson(raw)
        @Assert('topic', arg.name)
        @Assert('d', arg.description)
        @Assert(true, arg.required)
        @Assert(true, arg.toJson()['required'].asBool().value)
    }

    @TestCase
    public func testResourceContentRoundTrip(): Unit {
        let raw = JsonValue.fromStr('{"uri":"file:///a","mimeType":"text/plain","text":"hi"}').asObject()
        let content = ResourceContent.fromJson(raw)
        @Assert('file:///a', content.uri)
        @Assert('hi', content.text.getOrThrow())
        @Assert('text/plain', content.mimeType.getOrThrow())
        @Assert(true, content.toJson().contains('uri'))
    }

    @TestCase
    public func testPromptMessageRoundTrip(): Unit {
        let raw = JsonValue.fromStr('{"role":"assistant","content":{"type":"text","text":"yo"}}').asObject()
        let message = PromptMessage.fromJson(raw)
        @Assert('assistant', message.role)
        @Assert('text', message.content.kind())
        @Assert('yo', message.toJson()['content'].asObject()['text'].asString().value)
    }
}
