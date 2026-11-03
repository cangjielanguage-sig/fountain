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
import std.sync.*

import fountain::f_data.*

/** 一条演进记录 */
public class EvolutionRecord {
    public let docId: String
    public let skillTitle: String
    public let action: String
    public let detail: String
    public let at: Int64

    public init(docId: String, skillTitle: String, action: String,
                detail: String, at: Int64) {
        this.docId = docId
        this.skillTitle = skillTitle
        this.action = action
        this.detail = detail
        this.at = at
    }
}

/**
 * 技能演进报告库：每轮演进的结果都留档（谁演进、成败、原因、时间）。
 *
 * 存储落在知识库里（docId 前缀 `loom:evolution:`）而不是新建一张表：
 * 这样 f_store / PG / MySQL 三种部署都自动有持久化，不需要各自的 DDL 与仓储。
 * 查询按 docId 前缀过滤——`knowledge.docIds` 一次取一页，够用。
 */
public class SkillEvolutionLedger {
    private static let PREFIX = 'loom:evolution:'
    private static let mutex = Mutex()
    private static var seq: Int64 = 0

    private init() {
    }

    /** 把一轮报告写进报告库，返回写入条数 */
    public static func write(gateway: LoomStoreGateway, report: SkillEvolutionReport,
                             at: Int64): Int64 {
        var written: Int64 = 0
        for(item in report.evolved){
            if(append(gateway, item, 'evolved', item, at)){
                written++
            }
        }
        for(item in report.created){
            if(append(gateway, item, 'created', item, at)){
                written++
            }
        }
        for(item in report.rejected){
            if(append(gateway, item, 'rejected', item, at)){
                written++
            }
        }
        for(item in report.skipped){
            if(append(gateway, item, 'skipped', item, at)){
                written++
            }
        }
        written
    }

    /** 最近若干条（按 docId 的递增序号倒序返回） */
    public static func list(gateway: LoomStoreGateway, limit!: Int64 = 20): ArrayList<EvolutionRecord> {
        let result = ArrayList<EvolutionRecord>()
        let ids = try{
            gateway.call('knowledge', 'docIds', '{"offset":0,"limit":500}')
        }catch(error: Exception){
            '[]'
        }
        let parsed = match(JsonValue.fromStr(ids) as JsonArray){
            case Some(value) => value
            case None => return result
        }
        let matched = ArrayList<String>()
        for(item in parsed){
            match(item as JsonString){
                case Some(text) =>
                    if(text.value.startsWith(PREFIX)){
                        matched.add(text.value)
                    }
                case None => ()
            }
        }
        // docId 里带递增序号：从后往前取，等价于「最近的在前」
        var index = matched.size - 1
        while(index >= 0 && Int64(result.size) < limit){
            match(read(gateway, matched[index])){
                case Some(record) => result.add(record)
                case None => ()
            }
            index--
        }
        result
    }

    private static func append(gateway: LoomStoreGateway, line: String,
                               action: String, detail: String, at: Int64): Bool {
        let docId = '${PREFIX}${nextSeq()}'
        // 报告行形如 `技能名: 原因`，标题取冒号前那段
        let title = if(line.contains(':')){ line.split(':')[0].trimAscii() }else{ line }
        let payload = '{"docId":${FlowPlan.jsonQuote(docId)},'
            + '"title":${FlowPlan.jsonQuote('${title} ${action}')},'
            + '"content":${FlowPlan.jsonQuote(contentOf(title, action, line, at))}}'
        try{
            gateway.call('knowledge', 'upsert', payload)
            true
        }catch(error: Exception){
            false
        }
    }

    private static func contentOf(skillTitle: String, action: String,
                                  detail: String, at: Int64): String {
        '{"skill":${FlowPlan.jsonQuote(skillTitle)},'
            + '"action":${FlowPlan.jsonQuote(action)},'
            + '"detail":${FlowPlan.jsonQuote(detail)},'
            + '"at":${at}}'
    }

    private static func read(gateway: LoomStoreGateway, docId: String): ?EvolutionRecord {
        let text = try{
            gateway.call('knowledge', 'get', '{"docId":${FlowPlan.jsonQuote(docId)}}')
        }catch(error: Exception){
            ''
        }
        if(text.trimAscii().isEmpty()){
            return None
        }
        let doc = match(JsonValue.fromStr(text) as JsonObject){
            case Some(value) => value
            case None => return None
        }
        let content = match(doc.get('content')){
            case Some(value) =>
                match(value as JsonString){
                    case Some(field) => field.value
                    case None => ''
                }
            case None => ''
        }
        if(content.isEmpty() || !content.startsWith('{')){
            return None
        }
        let parsed = match(JsonValue.fromStr(content) as JsonObject){
            case Some(value) => value
            case None => return None
        }
        let at = match(parsed.get('at')){
            case Some(value) => Int64.tryParse(value.toString()) ?? 0
            case None => 0
        }
        EvolutionRecord(docId, strOf(parsed, 'skill'), strOf(parsed, 'action'),
                        strOf(parsed, 'detail'), at)
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

    private static func nextSeq(): Int64 {
        let box = SeqCounterBox()
        synchronized(mutex){
            seq++
            box.value = seq
        }
        box.value
    }
}

class SeqCounterBox {
    public var value: Int64 = 0
}
