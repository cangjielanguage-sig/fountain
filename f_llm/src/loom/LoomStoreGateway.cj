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
 * 目前开放的只读/删除类操作（不改写模型字段，避免 DTO 与 JSON 互相绑死）：
 *
 * | kind | op | payload | 返回 |
 * |---|---|---|---|
 * | `knowledge` | `docIds` | `{"offset":0,"limit":50}` | JSON 字符串数组 |
 * | `knowledge` | `remove` | `{"docId":"x"}` | `true` / `false` |
 * | `memory` | `remove` | `{"userId":1,"id":2}` | `true` / `false` |
 * | `skill` | `remove` | `{"id":3}` | `true` / `false` |
 * | `skill` | `count` | `{}` | 整数 |
 *
 * 未列出的 op 一律抛 [LoomException]，避免「静默返回空」被流程当成真实结果。
 */
public class LoomStoreGateway {
    private let content: ContentStore
    private let meta: MetaStore

    public init(content: ContentStore, meta: MetaStore) {
        this.content = content
        this.meta = meta
    }

    /** 容器用：取当前配置的内容族与元数据族 */
    public init() {
        this.content = Stores.content()
        this.meta = Stores.meta()
    }

    public func call(kind: String, op: String, payload: String): String {
        let args = parse(payload)
        let name = kind.trimAscii().toAsciiLower()
        let action = op.trimAscii().toAsciiLower()
        if(name == 'knowledge'){
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
        if(name == 'memory' && action == 'search'){
            let namespaces = ArrayList<String>()
            let namespace = strOf(args, 'namespace')
            if(!namespace.isEmpty()){
                namespaces.add(namespace)
            }
            let kinds = ArrayList<String>()
            let kind = strOf(args, 'kind')
            if(!kind.isEmpty()){
                kinds.add(kind)
            }
            let topK = intOf(args, 'topK')
            let hits = content.memory.search(MemoryQuery(intOf(args, 'userId'),
                namespaces.toArray(), kinds.toArray(), strOf(args, 'text'),
                topK: if(topK > 0){ topK }else{ 5 }))
            var text = '['
            var first = true
            for(hit in hits){
                if(!first){
                    text += ','
                }
                first = false
                text += '{"id":${hit.record.id},"title":${FlowPlan.jsonQuote(hit.record.title)}'
                text += ',"score":${hit.score}}'
            }
            return text + ']'
        }
        if(name == 'memory' && action == 'remove'){
            return content.memory.remove(intOf(args, 'userId'), intOf(args, 'id')).toString()
        }
        if(name == 'memory' && action == 'add'){
            let write = MemoryWrite(intOf(args, 'userId'), strOf(args, 'namespace'),
                strOf(args, 'title'), strOf(args, 'content'), strOf(args, 'kind'))
            return content.memory.add(write).id.toString()
        }
        if(name == 'skill' && action == 'remove'){
            return meta.skills.remove(intOf(args, 'id')).toString()
        }
        if(name == 'skill' && action == 'count'){
            return Int64(meta.skills.list().size).toString()
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
