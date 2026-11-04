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
package fountain::f_llm.store.mysql

import std.collection.*
import std.sync.*

import fountain::f_orm.*

import fountain::f_llm.store.*
import fountain::f_llm.dao.mysql.*

/** MySQL 版演进状态表（与 PG 版同构：每技能一条 + `__run__` 水位线） */
public class MySqlEvolutionStateStore <: EvolutionStateStore & RootService {
    private static let DRIVER = 'mysql'
    private static let RUN_ROW = '__run__'

    private let mutex = Mutex()
    private var tableReady = false

    public init() {
    }

    public func ensureSchema(): Unit {
        synchronized(mutex){
            daoOf().ensureStateTable()
            tableReady = true
        }
    }

    public func get(skillTitle: String): ?EvolutionSkillState {
        let box = MyStateBox()
        synchronized(mutex){
            ensureReady()
            for(row in daoOf().getState(skillTitle)){
                box.value = Some(EvolutionSkillState(skillTitle,
                    myStateIntOf(row.get('last_evolved_at') ?? 0),
                    myStateIntOf(row.get('gate_passed') ?? 0) == 1))
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

    private func ensureReady(): Unit {
        if(tableReady){
            return
        }
        daoOf().ensureStateTable()
        tableReady = true
    }

    private func daoOf(): MySqlEvolutionStateDAO {
        dao<MySqlEvolutionStateDAO>(DRIVER)
    }
}

private func myStateIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case number: Int16 => Int64(number)
        case text: String => Int64.tryParse(text) ?? 0
        case _ => 0
    }
}

class MyStateBox {
    public var value: ?EvolutionSkillState = None
}
