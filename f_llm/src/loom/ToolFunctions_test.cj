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

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_llm.tool.*

/** 供工具目录检索用的假工具（全局注册，测试内自证） */
class FakeCatalogTool <: CommonFunctionCalling {
    public prop name: String {
        get() {
            'loomTestEcho'
        }
    }

    public prop description: String {
        get() {
            'echo arguments for catalog search test'
        }
    }

    public prop definition: JsonObject {
        get() {
            let def = JsonObject()
            def.add('type', JsonString('function'))
            let body = JsonObject()
            def.add('function', body)
            body.add('name', JsonString(name))
            body.add('description', JsonString(description))
            body.add('parameters', JsonObject())
            def
        }
    }

    public func call(json: JsonObject): FunctionResult {
        FunctionResult(event: 'next', result: '')
    }
}

/** listTools / searchTools */
@Test
class ToolFunctions_test {
    private static func listParam(json: String): ListToolsParam {
        match(DataObject<ListToolsParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad param: ${json}')
        }
    }

    private static func searchParam(json: String): SearchToolsParam {
        match(DataObject<SearchToolsParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw IllegalStateException('bad param: ${json}')
        }
    }

    private static func textOf(result: FunctionResult): String {
        match(result.result as JsonString){
            case Some(value) => value.value
            case None => ''
        }
    }

    /** 同一进程内多个用例共用注册表：重复注册直接忽略 */
    private static func ensureFake(): Unit {
        try{
            FunctionMediator.register(FakeCatalogTool())
        }catch(error: Exception){
            ()
        }
    }

    @TestCase
    func testListIncludesRegisteredTool(): Unit {
        ensureFake()
        let result = ListToolsFunction().call(listParam('{"nextEvent":"next","offset":"0","limit":"50"}'))
        @Expect(textOf(result).contains('loomTestEcho'), true)
    }

    @TestCase
    func testSearchMatchesName(): Unit {
        ensureFake()
        let result = SearchToolsFunction().call(searchParam(
            '{"nextEvent":"next","query":"echo","topK":"5"}'))
        let text = textOf(result)
        @Expect(text.contains('loomTestEcho'), true)
        @Expect(text.contains('"score"'), true)
    }

    @TestCase
    func testSearchRequiresQuery(): Unit {
        let result = SearchToolsFunction().call(searchParam('{"nextEvent":"next"}'))
        @Expect(textOf(result).contains('requires query'), true)
    }

    @TestCase
    func testSearchMissReturnsEmptyArray(): Unit {
        ensureFake()
        let result = SearchToolsFunction().call(searchParam(
            '{"nextEvent":"next","query":"zzz-not-exist","topK":"5"}'))
        @Expect(textOf(result), '[]')
    }
}
