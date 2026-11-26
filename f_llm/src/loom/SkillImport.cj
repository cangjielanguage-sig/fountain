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
import std.fs.{File, OpenMode, exists}
import std.io.StringReader

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_data.macros.*

// 注意：`Skill` 有两个同名类，SkillStore 用它自己的 `store.Skill`
import fountain::f_llm.store.{Skill, SkillStore, Stores}
import fountain::f_llm.tool.*

/**
 * 技能包（目录格式）：
 *
 * ```
 * skill-package/
 * ├── skill.json   {"title":"…","acceptedEvent":"…","returnedEvent":"…","metadata":{…},"version":1}
 * └── details.md   技能正文
 * ```
 *
 * `StoreModels.Skill` 只有 `id/title/details/functions/version` 五个字段且不可变，
 * 因此把 `acceptedEvent` / `returnedEvent` / `metadata` 原样收进 `functions`（JSON 文本），
 * 既不丢信息，也不需要改存储模型。
 */
public class SkillPackage {
    public let title: String
    public let details: String
    public let functions: String
    public let version: Int64

    public init(title: String, details: String, functions: String, version: Int64) {
        this.title = title
        this.details = details
        this.functions = functions
        this.version = version
    }
}

public class SkillImporter {
    private init() {
    }

    /** 解析目录为技能包（尚未分配 id） */
    public static func parse(dir: String): SkillPackage {
        let root = dir.trimAscii()
        if(root.isEmpty()){
            throw LoomException('skill package path is empty')
        }
        let manifest = '${root}/skill.json'
        if(!exists(manifest)){
            throw LoomException('skill package missing skill.json: ${root}')
        }
        let json = match(JsonValue.fromStr(readAll(manifest)) as JsonObject){
            case Some(value) => value
            case None => throw LoomException('skill.json is not a JSON object: ${root}')
        }
        let title = strOf(json, 'title')
        if(title.isEmpty()){
            throw LoomException('skill.json requires title: ${root}')
        }
        let detailsPath = '${root}/details.md'
        let details = if(exists(detailsPath)){ readAll(detailsPath) }else{ '' }

        var functions = '{"acceptedEvent":${FlowPlan.jsonQuote(strOf(json, 'acceptedEvent'))},'
        functions += '"returnedEvent":${FlowPlan.jsonQuote(strOf(json, 'returnedEvent'))},'
        functions += '"metadata":'
        functions += match(json.get('metadata')){
            case Some(value) => value.toString()
            case None => '{}'
        }
        functions += '}'

        let version = match(json.get('version')){
            case Some(value) => Int64.tryParse(value.toString()) ?? 1
            case None => 1
        }
        SkillPackage(title, details, functions, version)
    }

    /** 解析并写入 store；同名 title 复用原 id 覆盖写（幂等） */
    public static func importInto(dir: String, store: SkillStore): Skill {
        let pkg = parse(dir)
        var maxId: Int64 = 0
        var matched: ?Skill = None
        for(item in store.list()){
            if(item.id > maxId){
                maxId = item.id
            }
            if(item.title == pkg.title){
                matched = Some(item)
            }
        }
        let id = match(matched){
            case Some(existing) => existing.id
            case None => maxId + 1
        }
        let skill = Skill(id, pkg.title, pkg.details, pkg.functions, version: pkg.version)
        store.upsert(skill)
        skill
    }

    private static func readAll(path: String): String {
        let file = File(path, OpenMode.Read)
        let text = StringReader(file).readToEnd()
        file.close()
        text
    }

    private static func strOf(json: JsonObject, key: String): String {
        match(json.get(key)){
            case Some(value) =>
                match(value as JsonString){
                    case Some(text) => text.value
                    case None => ''
                }
            case None => ''
        }
    }
}

/** 模型可调用的技能导入入口 */
@DataAssist[props fields]
public class SkillImportParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'技能包目录（含 skill.json 与 details.md）']
    private var path: String = ''
}

@Bean
public class SkillImportFunction <: FunctionCalling<SkillImportParam> {
    private let injected: ?SkillStore

    public init(store!: ?SkillStore = None) {
        this.injected = store
    }

    public prop name: String {
        get() {
            'skillImport'
        }
    }

    public prop description: String {
        get() {
            '从目录导入技能包（skill.json + details.md），同名 title 覆盖'
        }
    }

    public func call(params: SkillImportParam): FunctionResult {
        if(params.path.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent, result: 'skillImport requires path')
        }
        try{
            let store = match(injected){
                case Some(value) => value
                case None => Stores.meta().skills
            }
            let skill = SkillImporter.importInto(params.path, store)
            FunctionResult(event: params.nextEvent,
                result: 'imported: ${skill.title} (id=${skill.id})')
        }catch(error: Exception){
            FunctionResult(event: params.nextEvent, result: 'skillImport failed: ${error.message}')
        }
    }
}
