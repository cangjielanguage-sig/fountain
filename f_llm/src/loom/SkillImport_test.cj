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
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_llm.store.*
import fountain::f_llm.tool.*

/** skillImport：目录解析、幂等覆盖、缺文件报错 */
@Test
class SkillImport_test {
    private static func packageDir(tag: String): String {
        let dir = '/tmp/loom-skill-${tag}'
        if(!exists(dir)){
            Directory.create(dir, recursive: true)
        }
        dir
    }

    private static func writeFile(path: String, text: String): Unit {
        let file = File(path, OpenMode.Write)
        file.write(text.toArray())
        file.close()
    }

    private static func writePackage(dir: String, title: String): Unit {
        writeFile('${dir}/skill.json',
            '{"title":"${title}","acceptedEvent":"a","returnedEvent":"b","metadata":{"k":"v"}}')
        writeFile('${dir}/details.md', '# 技能正文\n按需检索记忆后作答。')
    }

    private static func importParam(json: String): SkillImportParam {
        match(DataObject<SkillImportParam>.populate(JsonValue.fromStr(json).toData())){
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

    @TestCase
    func testImportWritesSkill(): Unit {
        let dir = packageDir('basic')
        writePackage(dir, '日报助手')
        let store = InMemoryMetaStore().skills
        let result = SkillImportFunction(store: store).call(importParam(
            '{"nextEvent":"next","path":"${dir}"}'))
        @Expect(textOf(result).contains('imported: 日报助手'), true)
        @Expect(store.list().size, 1)
        @Expect(store.list()[0].details.contains('技能正文'), true)
    }

    @TestCase
    func testReimportSameTitleKeepsId(): Unit {
        let dir = packageDir('idempotent')
        writePackage(dir, '同款技能')
        let store = InMemoryMetaStore().skills
        let function = SkillImportFunction(store: store)
        function.call(importParam('{"nextEvent":"next","path":"${dir}"}'))
        let firstId = store.list()[0].id
        function.call(importParam('{"nextEvent":"next","path":"${dir}"}'))
        @Expect(store.list().size, 1)
        @Expect(store.list()[0].id, firstId)
    }

    @TestCase
    func testMissingManifestReturnsText(): Unit {
        let dir = packageDir('missing')
        let result = SkillImportFunction(store: InMemoryMetaStore().skills).call(importParam(
            '{"nextEvent":"next","path":"${dir}"}'))
        @Expect(textOf(result).contains('missing skill.json'), true)
    }

    @TestCase
    func testRequiresPath(): Unit {
        let result = SkillImportFunction(store: InMemoryMetaStore().skills).call(
            importParam('{"nextEvent":"next"}'))
        @Expect(textOf(result).contains('requires path'), true)
    }
}
