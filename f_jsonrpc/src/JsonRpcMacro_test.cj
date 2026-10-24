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
package fountain::f_jsonrpc

import std.collection.ArrayList
import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.DataAssist
import fountain::f_jsonrpc.macros.*

@DataAssist[fields props]
public class MacroEcho {
    public var text: String = ''

    public init() {}

    public init(text: String) {
        this.text = text
    }
}

@JsonRpc[topic: kb]
public class JsonRpcMacroTestRPC {
    public init() {}

    @JsonRpcMeta['知识库检索', '5s']
    public func search(param: String): String {
        'found:${param}'
    }

    @JsonRpcMeta['加法', '1s']
    public func add(a: Int64, b: Int64): Int64 {
        a + b
    }

    @JsonRpcMeta['通知', '']
    public func touch(): Unit {}

    public func echo(req: MacroEcho): MacroEcho {
        MacroEcho(req.text + '!')
    }

    private func hidden(): String {
        'x'
    }
}

public class JsonRpcOverloadTestRPC {
    @JsonRpcMeta['字符串重载', '1s']
    public func pick(value: String): String {
        value
    }

    @JsonRpcMeta['整数重载', '2s']
    public func pick(value: Int64): Int64 {
        value
    }
}

@Test
class JsonRpcMacro_test {
    static func call(method: String, params: String, topic!: String = ''): JsonObject {
        let body = '{"jsonrpc":"2.0","id":1,"method":"${method}","params":${params}}'
        let ctx = JsonRpcContext(topic: topic)
        let bytes = JsonRpcRegistry.server().handle(body.unsafeBytes(), ctx: ctx).getOrThrow()
        JsonValue.fromBytes(bytes).asObject()
    }

    static func errorCode(obj: JsonObject): Int64 {
        obj['error'].asObject()['code'].asInt().toInt64()
    }

    @TestCase
    public func testRegistersPublicMethods(): Unit {
        let names = ArrayList<String>()
        for (m in JsonRpcRegistry.server().methods()) {
            names.add(m.name)
        }
        @Assert(true, names.contains('kb.search'))
        @Assert(true, names.contains('kb.add'))
        @Assert(true, names.contains('kb.touch'))
        @Assert(true, names.contains('kb.echo'))
        @Assert(false, names.contains('kb.hidden'))
    }

    @TestCase
    public func testSingleParam(): Unit {
        let obj = call('kb.search', '["hello"]')
        @Assert('found:hello', obj['result'].asString().value)
    }

    @TestCase
    public func testMultiParams(): Unit {
        let obj = call('kb.add', '{"a":1,"b":2}')
        @Assert(3, obj['result'].asInt().toInt64())
    }

    @TestCase
    public func testMissingParam(): Unit {
        let obj = call('kb.add', '{"a":1}')
        @Assert(JsonRpcProtocol.INVALID_PARAMS, errorCode(obj))
    }

    @TestCase
    public func testInvalidType(): Unit {
        let obj = call('kb.search', '[null]')
        @Assert(JsonRpcProtocol.INVALID_PARAMS, errorCode(obj))
    }

    @TestCase
    public func testUnitResultIsNull(): Unit {
        let obj = call('kb.touch', '{}')
        @Assert(JsonKind.JsonNull, obj['result'].kind)
    }

    @TestCase
    public func testObjectParamAndResult(): Unit {
        let obj = call('kb.echo', '{"text":"hi"}')
        @Assert('hi!', obj['result'].asObject()['text'].asString().value)
    }

    @TestCase
    public func testMetaDescriptionAndTimeout(): Unit {
        var found = false
        for (m in JsonRpcRegistry.server().methods()) {
            if (m.name == 'kb.search') {
                found = true
                @Assert('知识库检索', m.description)
                @Assert(true, m.timeout.getOrThrow() == Duration.parse('5s'))
            }
        }
        @Assert(true, found)
    }

    @TestCase
    public func testBareMethodUsesDefaultTimeout(): Unit {
        for (m in JsonRpcRegistry.server().methods()) {
            if (m.name == 'kb.echo') {
                @Assert('', m.description)
                @Assert(true, m.timeout.getOrThrow() == Duration.parse('500ms'))
            }
        }
    }

    @TestCase
    public func testAnnotationVisibleByReflection(): Unit {
        let functions = TypeInfo.of<JsonRpcMacroTestRPC>().getInstanceFunctions('search')
        @Assert(1, functions.size)
        @Assert(true, functions[0].findAnnotation<JsonRpcMeta>().isSome())
    }

    @TestCase
    public func testGetMetaReadsAnnotation(): Unit {
        let f = TypeInfo.of<JsonRpcMacroTestRPC>().getInstanceFunctions('search')[0]
        @Assert(true, f.findAnnotation<JsonRpcMeta>().isSome())
        @Assert('知识库检索', JsonRpcRegistry.getMeta<JsonRpcMacroTestRPC>('search', [TypeInfo.of<String>()]).description)
    }

    @TestCase
    public func testTimeoutDuration(): Unit {
        let meta = JsonRpcRegistry.getMeta<JsonRpcMacroTestRPC>('search', [TypeInfo.of<String>()])
        @Assert('知识库检索', meta.description)
        @Assert(true, meta.timeoutDuration == Duration.parse('5s'))
    }

    @TestCase
    public func testMissingMetaUsesDefaultTimeout(): Unit {
        let meta = JsonRpcRegistry.getMeta<JsonRpcMacroTestRPC>('echo', [TypeInfo.of<MacroEcho>()])
        @Assert('', meta.description)
        @Assert('500ms', meta.timeout)
        @Assert(true, meta.timeoutDuration == Duration.parse('500ms'))
    }

    @TestCase
    public func testGetMetaMatchesOverloadByArgTypes(): Unit {
        let text = JsonRpcRegistry.getMeta<JsonRpcOverloadTestRPC>('pick', [TypeInfo.of<String>()])
        @Assert('字符串重载', text.description)
        let number = JsonRpcRegistry.getMeta<JsonRpcOverloadTestRPC>('pick', [TypeInfo.of<Int64>()])
        @Assert('整数重载', number.description)
        let missing = JsonRpcRegistry.getMeta<JsonRpcOverloadTestRPC>('pick', [TypeInfo.of<Bool>()])
        @Assert('', missing.description)
    }

    @TestCase
    public func testTopicRouting(): Unit {
        let ok = call('kb.search', '["x"]', topic: 'kb')
        @Assert(true, ok.contains('result'))
        let other = call('kb.search', '["x"]', topic: 'other')
        @Assert(JsonRpcProtocol.UNKNOWN_TOPIC, errorCode(other))
    }
}
