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
        }
        if(name == 'memory' && action == 'remove'){
            return content.memory.remove(intOf(args, 'userId'), intOf(args, 'id')).toString()
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
                match(value as JsonInt){
                    case Some(number) => Int64.tryParse(number.value.toString()) ?? 0
                    case None => Int64.tryParse(strOf(args, key)) ?? 0
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
