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

import fountain::f_data.*
import fountain::f_llm.store.*

/**
 * `loomStore(kind, op, payload)` 的默认实现：把字符串请求映射到 f_llm 的 Store。
 *
 * | kind | op | payload | 返回 |
 * |---|---|---|---|
 * | `knowledge` | `get` | `{"docId":"d1"}` | 文档 JSON，未命中 `''` |
 * | `knowledge` | `docIds` | `{"offset":0,"limit":50}` | JSON 字符串数组 |
 * | `knowledge` | `search` | `{"text":"…","limit":5}` | `[{docId,seq,score,content}]` |
 * | `knowledge` | `upsert` | `{"docId","title","content"}` | `ok` |
 * | `knowledge` | `remove` | `{"docId":"d1"}` | `true/false` |
 * | `memory` | `add` | `{"userId","namespace","title","content","kind"}` | 记录 id |
 * | `memory` | `get` | `{"userId":1,"id":2}` | 记录 JSON，未命中 `''` |
 * | `memory` | `list` | `{"userId","namespace","offset","limit"}` | 记录数组 |
 * | `memory` | `search` | `{"userId","namespace","text","topK"}` | `[{id,title,score}]` |
 * | `memory` | `remove` | `{"userId":1,"id":2}` | `true/false` |
 * | `skill` | `get` | `{"id":1}` | 技能 JSON，未命中 `''` |
 * | `skill` | `list` | `{}` | 技能数组 |
 * | `skill` | `count` | `{}` | 整数 |
 * | `skill` | `remove` | `{"id":1}` | `true/false` |
 * | `experience` | 同 `memory` | 同上，`kind` 缺省为 `experience` | 同上 |
 *
 * 未列出的 op 一律抛 [LoomException]，避免「静默返回空」被流程当成真实结果。
 */
public class LoomStoreGateway {
    private let content: ContentStore
    private let meta: MetaStore
    /** 演进报告表：可选，未装配时 `evolution.*` 抛可读错误 */
    private let evolution: ?EvolutionStore

    public init(content: ContentStore, meta: MetaStore,
                evolution!: ?EvolutionStore = None) {
        this.content = content
        this.meta = meta
        this.evolution = evolution
    }

    /** 容器用：取当前配置的内容族与元数据族 */
    public init() {
        this.content = Stores.content()
        this.meta = Stores.meta()
        // 零配置装配：报告表跟随 llm_metaStore（f_store / memory / postgres / mysql）
        this.evolution = Some(EvolutionStores.current())
    }

    public func call(kind: String, op: String, payload: String): String {
        let args = parse(payload)
        let rawName = kind.trimAscii().toAsciiLower()
        let action = op.trimAscii().toAsciiLower()
        // 经验 = 带 kind 的记忆：同一条链路，不另造存储
        let name = if(rawName == 'experience'){ 'memory' }else{ rawName }
        let defaultKind = if(rawName == 'experience'){ 'experience' }else{ '' }

        if(name == 'knowledge'){
            if(action == 'get'){
                match(content.knowledge.get(strOf(args, 'docId'))){
                    case Some(doc) =>
                        return '{"docId":${FlowPlan.jsonQuote(doc.docId)},'
                            + '"title":${FlowPlan.jsonQuote(doc.title)},'
                            + '"content":${FlowPlan.jsonQuote(doc.content)}}'
                    case None => return ''
                }
            }
            if(action == 'docids'){
                let ids = content.knowledge.docIds(intOf(args, 'offset'), intOf(args, 'limit'))
                return quotes(ids)
            }
            if(action == 'remove'){
                return content.knowledge.remove(strOf(args, 'docId')).toString()
            }
            if(action == 'upsert'){
                content.knowledge.upsert(KnowledgeDoc(strOf(args, 'docId'),
                    strOf(args, 'title'), strOf(args, 'content')))
                return 'ok'
            }
            if(action == 'search'){
                let limit = intOf(args, 'limit')
                let hits = content.knowledge.search(
                    KnowledgeQuery(strOf(args, 'text'), limit: if(limit > 0){ limit }else{ 5 }))
                var text = '['
                var first = true
                for(hit in hits){
                    if(!first){
                        text += ','
                    }
                    first = false
                    text += '{"docId":${FlowPlan.jsonQuote(hit.docId)},"seq":${hit.seq}'
                    text += ',"score":${hit.score},"content":${FlowPlan.jsonQuote(hit.content)}}'
                }
                return text + ']'
            }
        }

        if(name == 'memory'){
            let userId = intOf(args, 'userId')
            if(action == 'add'){
                let kindValue = kindOf(args, defaultKind)
                let write = MemoryWrite(userId, strOf(args, 'namespace'),
                    strOf(args, 'title'), strOf(args, 'content'), kindValue)
                return content.memory.add(write).id.toString()
            }
            if(action == 'get'){
                match(content.memory.get(userId, intOf(args, 'id'))){
                    case Some(record) => return recordJson(record)
                    case None => return ''
                }
            }
            if(action == 'list'){
                let kindFilter = strOf(args, 'kind')
                let records = if(kindFilter.isEmpty()){
                    content.memory.list(userId, strOf(args, 'namespace'),
                        intOf(args, 'offset'), intOf(args, 'limit'))
                }else{
                    // 交给 Store 过滤：先过滤再分页，不会出现「本页没有就判空」
                    content.memory.listByKind(userId, strOf(args, 'namespace'), kindFilter,
                        intOf(args, 'offset'), intOf(args, 'limit'))
                }
                var text = '['
                var first = true
                for(record in records){
                    if(!first){
                        text += ','
                    }
                    first = false
                    text += recordJson(record)
                }
                return text + ']'
            }
            if(action == 'search'){
                let namespaces = ArrayList<String>()
                let namespace = strOf(args, 'namespace')
                if(!namespace.isEmpty()){
                    namespaces.add(namespace)
                }
                let kinds = ArrayList<String>()
                let kindValue = kindOf(args, defaultKind)
                if(!kindValue.isEmpty()){
                    kinds.add(kindValue)
                }
                let topK = intOf(args, 'topK')
                let hits = content.memory.search(MemoryQuery(userId,
                    namespaces.toArray(), kinds.toArray(), strOf(args, 'text'),
                    topK: if(topK > 0){ topK }else{ 5 }))
                var text = '['
                var first = true
                for(hit in hits){
                    if(!first){
                        text += ','
                    }
                    first = false
                    text += '{"id":${hit.record.id},'
                    text += '"title":${FlowPlan.jsonQuote(hit.record.title)},'
                    text += '"score":${hit.score}}'
                }
                return text + ']'
            }
            if(action == 'remove'){
                return content.memory.remove(userId, intOf(args, 'id')).toString()
            }
        }

        if(name == 'skill'){
            if(action == 'remove'){
                return meta.skills.remove(intOf(args, 'id')).toString()
            }
            if(action == 'count'){
                return Int64(meta.skills.list().size).toString()
            }
            if(action == 'get'){
                match(meta.skills.get(intOf(args, 'id'))){
                    case Some(skill) => return skillJson(skill)
                    case None => return ''
                }
            }
            if(action == 'list'){
                var text = '['
                var first = true
                for(skill in meta.skills.list()){
                    if(!first){
                        text += ','
                    }
                    first = false
                    text += skillJson(skill)
                }
                return text + ']'
            }
            if(action == 'load'){
                // 按标题加载：流程里不需要知道 id
                let title = strOf(args, 'title')
                for(skill in meta.skills.list()){
                    if(skill.title == title){
                        return skillJson(skill)
                    }
                }
                return ''
            }
            if(action == 'upsert'){
                // id<=0 视为新建：取当前最大 id + 1
                var targetId = intOf(args, 'id')
                if(targetId <= 0){
                    var maxId: Int64 = 0
                    for(item in meta.skills.list()){
                        if(item.id > maxId){
                            maxId = item.id
                        }
                    }
                    targetId = maxId + 1
                }
                let version = intOf(args, 'version')
                meta.skills.upsert(Skill(targetId, strOf(args, 'title'),
                    strOf(args, 'details'), strOf(args, 'functions'),
                    version: if(version > 0){ version }else{ 1 }))
                return targetId.toString()
            }
        }

        if(name == 'prompt'){
            if(action == 'get'){
                match(meta.prompts.get(strOf(args, 'name'), intOf(args, 'version'))){
                    case Some(entry) => return promptJson(entry)
                    case None => return ''
                }
            }
            if(action == 'latest'){
                match(meta.prompts.latest(strOf(args, 'name'))){
                    case Some(entry) => return promptJson(entry)
                    case None => return ''
                }
            }
            if(action == 'put'){
                let name_ = strOf(args, 'name')
                if(name_.isEmpty()){
                    throw LoomException('loom store gateway: prompt.put requires name')
                }
                // version<=0：接在最新版本之后
                var version = intOf(args, 'version')
                if(version <= 0){
                    version = match(meta.prompts.latest(name_)){
                        case Some(entry) => entry.version + 1
                        case None => 1
                    }
                }
                meta.prompts.put(PromptEntry(name_, version, strOf(args, 'content')))
                return version.toString()
            }
            if(action == 'remove'){
                return meta.prompts.remove(strOf(args, 'name'), intOf(args, 'version')).toString()
            }
        }

        if(name == 'character'){
            let userId = intOf(args, 'userId')
            if(action == 'get'){
                match(meta.characters.get(userId)){
                    case Some(character) => return characterJson(character)
                    case None => return ''
                }
            }
            if(action == 'set'){
                meta.characters.set(Character(userId, strOf(args, 'characterKey'),
                    strOf(args, 'prompts')))
                return 'ok'
            }
            if(action == 'reset'){
                meta.characters.reset(userId)
                return 'ok'
            }
        }

        if(name == 'evolution'){
            let target = match(evolution){
                case Some(store) => store
                case None => throw LoomException('loom store gateway: evolution store is not installed')
            }
            if(action == 'save'){
                let id = target.save(EvolutionEntry(0, strOf(args, 'skill'),
                    strOf(args, 'action'), strOf(args, 'detail'), intOf(args, 'at')))
                return id.toString()
            }
            if(action == 'list'){
                return entriesJson(target.list(intOf(args, 'offset'), intOf(args, 'limit')))
            }
            if(action == 'by_skill'){
                let limit = intOf(args, 'limit')
                return entriesJson(target.bySkill(strOf(args, 'skill'),
                    if(limit > 0){ limit }else{ 20 }))
            }
        }

        throw LoomException('loom store gateway: unsupported ${kind}.${op}')
    }

    private static func parse(payload: String): JsonObject {
        let text = payload.trimAscii()
        if(text.isEmpty()){
            return JsonValue.fromStr('{}').asObject()
        }
        JsonValue.fromStr(text).asObject()
    }

    private static func strOf(args: JsonObject, key: String): String {
        match(args.get(key)){
            case Some(value) =>
                match(value as JsonString){
                    case Some(text) => text.value
                    case None => ''
                }
            case None => ''
        }
    }

    private static func kindOf(args: JsonObject, defaultKind: String): String {
        let explicit = strOf(args, 'kind')
        if(!explicit.isEmpty()){
            return explicit
        }
        defaultKind
    }

    private static func intOf(args: JsonObject, key: String): Int64 {
        match(args.get(key)){
            case Some(value) =>
                // JSON 数字可能是 JsonInt 或浮点类，统一按文本回退解析
                let text = value.toString()
                match(Int64.tryParse(text)){
                    case Some(number) => number
                    case None =>
                        match(Float64.tryParse(text)){
                            case Some(number) => Int64(number)
                            case None => 0
                        }
                }
            case None => 0
        }
    }

    private static func recordJson(record: MemoryRecord): String {
        '{"id":${record.id},"userId":${record.userId},'
            + '"namespace":${FlowPlan.jsonQuote(record.namespace)},'
            + '"title":${FlowPlan.jsonQuote(record.title)},'
            + '"content":${FlowPlan.jsonQuote(record.content)},'
            + '"kind":${FlowPlan.jsonQuote(record.kind)}}'
    }

    private static func skillJson(skill: Skill): String {
        '{"id":${skill.id},"title":${FlowPlan.jsonQuote(skill.title)},'
            + '"details":${FlowPlan.jsonQuote(skill.details)},'
            + '"version":${skill.version}}'
    }

    private static func entriesJson(entries: ArrayList<EvolutionEntry>): String {
        var text = '['
        var first = true
        for(entry in entries){
            if(!first){
                text += ','
            }
            first = false
            text += '{"id":${entry.id},'
                + '"skill":${FlowPlan.jsonQuote(entry.skillTitle)},'
                + '"action":${FlowPlan.jsonQuote(entry.action)},'
                + '"detail":${FlowPlan.jsonQuote(entry.detail)},'
                + '"at":${entry.at}}'
        }
        text + ']'
    }

    private static func promptJson(entry: PromptEntry): String {
        '{"name":${FlowPlan.jsonQuote(entry.name)},"version":${entry.version},'
            + '"content":${FlowPlan.jsonQuote(entry.content)}}'
    }

    private static func characterJson(character: Character): String {
        '{"userId":${character.userId},'
            + '"characterKey":${FlowPlan.jsonQuote(character.characterKey)},'
            + '"prompts":${FlowPlan.jsonQuote(character.prompts)}}'
    }

    private static func quotes(values: ArrayList<String>): String {
        var text = '['
        var first = true
        for(item in values){
            if(!first){
                text += ','
            }
            first = false
            text += FlowPlan.jsonQuote(item)
        }
        text + ']'
    }
}
