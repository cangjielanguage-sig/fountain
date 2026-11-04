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
package fountain::f_llm.store.postgres

import std.collection.*
import std.sync.*
import std.time.DateTime

import fountain::f_orm.*

import fountain::f_llm.store.*
import fountain::f_llm.dao.postgres.*

/**
 * PostgreSQL 版演进状态表。
 *
 * 水位线借用同一张表的保留行 `__run__`：省一张表，也让「状态」与「水位线」
 * 在同一次事务语义下维护（当前无显式事务，但至少是同库同表）。
 */
public class PostgresEvolutionStateStore <: EvolutionStateStore & RootService {
    private static let DRIVER = 'postgres'
    /** 保留技能名：只存整轮水位线，不会与真实技能冲突 */
    private static let RUN_ROW = '__run__'
    /** 单次最多读回的已消费记录数：只用于去重，不必取全量 */
    private static let KNOWLEDGE_LIMIT: Int64 = 5000

    private let mutex = Mutex()
    private var tableReady = false

    public init() {
    }

    public func ensureSchema(): Unit {
        synchronized(mutex){
            daoOf().ensureStateTable()
            daoOf().ensureKnowledgeTable()
            tableReady = true
        }
    }

    public func get(skillTitle: String): ?EvolutionSkillState {
        let box = PgStateBox()
        synchronized(mutex){
            ensureReady()
            for(row in daoOf().getState(skillTitle)){
                box.value = Some(EvolutionSkillState(skillTitle,
                    pgIntOf(row.get('last_evolved_at') ?? 0),
                    pgIntOf(row.get('gate_passed') ?? 0) == 1))
            }
        }
        box.value
    }

    public func save(state: EvolutionSkillState): Unit {
        synchronized(mutex){
            ensureReady()
            daoOf().upsertState(state.skillTitle, state.lastEvolvedAt,
                if(state.lastGatePassed){ 1 }else{ 0 })
        }
    }

    public func lastRunAt(): Int64 {
        match(get(RUN_ROW)){
            case Some(state) => state.lastEvolvedAt
            case None => 0
        }
    }

    public func markRun(at: Int64): Unit {
        save(EvolutionSkillState(RUN_ROW, at, true))
    }

    /** 已消费的知识 docId：落在 `llm_skill_evolution_knowledge` */
    public func processedKnowledge(): Array<String> {
        let box = PgKnowledgeBox()
        synchronized(mutex){
            ensureReady()
            let list = ArrayList<String>()
            for(row in daoOf().knowledgeList(KNOWLEDGE_LIMIT)){
                list.add(pgTextOf(row.get('doc_id') ?? ''))
            }
            box.value = list.toArray()
        }
        box.value
    }

    public func markKnowledge(docIds: Array<String>): Unit {
        synchronized(mutex){
            ensureReady()
            let at = DateTime.now().toUnixTimeStamp().toSeconds()
            for(docId in docIds){
                if(!docId.isEmpty()){
                    let _ = daoOf().knowledgeInsert(docId, at)
                }
            }
        }
    }

    private func ensureReady(): Unit {
        if(tableReady){
            return
        }
        daoOf().ensureStateTable()
        daoOf().ensureKnowledgeTable()
        tableReady = true
    }

    private func daoOf(): PostgresEvolutionStateDAO {
        dao<PostgresEvolutionStateDAO>(DRIVER)
    }
}

private func pgIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case number: Int16 => Int64(number)
        case text: String => Int64.tryParse(text) ?? 0
        case _ => 0
    }
}

private func pgTextOf(value: Any): String {
    match(value){
        case text: String => text
        case _ => ''
    }
}

class PgKnowledgeBox {
    public var value: Array<String> = Array<String>()
}

class PgStateBox {
    public var value: ?EvolutionSkillState = None
}
