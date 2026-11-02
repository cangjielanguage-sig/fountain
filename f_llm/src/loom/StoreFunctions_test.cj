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
package fountain::f_llm.loom

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_llm.store.*
import fountain::f_llm.tool.*

/** memoryCall / knowledgeIngest 两个工具入口 */
@Test
class StoreFunctions_test {
    private static func gateway(): LoomStoreGateway {
        LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
    }

    private static func memoryParam(json: String): MemoryCallParam {
        match(DataObject<MemoryCallParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad memory param: ${json}')
        }
    }

    private static func ingestParam(json: String): KnowledgeIngestParam {
        match(DataObject<KnowledgeIngestParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad ingest param: ${json}')
        }
    }

    private static func textOf(result: FunctionResult): String {
        match(result.result as JsonString){
            case Some(value) => value.value
            case None => ''
        }
    }

    @TestCase
    func testMemoryAddThenSearch(): Unit {
        let gateway = gateway()
        let function = MemoryCallFunction(gateway: gateway)
        let addBody = '{"userId":7,"namespace":"n","title":"note","content":"cangjie","kind":"fact"}'
        let added = function.call(memoryParam('{"nextEvent":"next","op":"add","payload":'
            + FlowPlan.jsonQuote(addBody) + '}'))
        // 写入成功时应返回记录 id，而不是错误文本
        @Expect(textOf(added).contains('failed'), false)
        let searchBody = '{"userId":7,"namespace":"n","text":"cangjie","topK":5}'
        let hits = function.call(memoryParam('{"nextEvent":"next","op":"search","payload":'
            + FlowPlan.jsonQuote(searchBody) + '}'))
        @Expect(textOf(hits).startsWith('['), true)
    }

    @TestCase
    func testMemoryInvalidOpReturnsText(): Unit {
        let function = MemoryCallFunction(gateway: gateway())
        let result = function.call(memoryParam('{"nextEvent":"next","op":"purge"}'))
        @Expect(textOf(result).contains('unsupported memoryCall op'), true)
    }

    @TestCase
    func testKnowledgeIngestWritesDoc(): Unit {
        let gateway = gateway()
        let function = KnowledgeIngestFunction(gateway: gateway)
        function.call(ingestParam('{"nextEvent":"next","docId":"d1","title":"t","content":"hello"}'))
        @Expect(gateway.call('knowledge', 'docIds', '{"offset":0,"limit":10}'), '["d1"]')
    }

    @TestCase
    func testKnowledgeIngestRequiresDocId(): Unit {
        let function = KnowledgeIngestFunction(gateway: gateway())
        let result = function.call(ingestParam('{"nextEvent":"next","title":"t"}'))
        @Expect(textOf(result).contains('requires docId'), true)
    }
}
