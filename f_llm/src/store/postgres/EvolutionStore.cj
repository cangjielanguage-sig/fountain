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

import fountain::f_orm.*

import fountain::f_llm.store.*
import fountain::f_llm.dao.postgres.*

/**
 * PostgreSQL 版演进报告表。
 *
 * `id` 由本类用 `MAX(id)+1` 分配（表里没有自增列），这样 PG 与 MySQL 的写入口径一致，
 * 也不依赖各驱动对 `RETURNING` / `LAST_INSERT_ID()` 的支持差异。
 * 演进是低频批处理，单进程写足够。
 */
public class PostgresEvolutionStore <: EvolutionStore & RootService {
    private static let DRIVER = 'postgres'

    private let mutex = Mutex()
    private var tableReady = false
    private var nextId: Int64 = 0

    public init() {
    }

    public func save(entry: EvolutionEntry): Int64 {
        let box = EvoIdBox()
        synchronized(mutex){
            let dao = daoOf()
            ensure(dao)
            var id = entry.id
            if(id <= 0){
                if(nextId <= 0){
                    nextId = maxIdOf(dao)
                }
                nextId++
                id = nextId
            }else if(id > nextId){
                nextId = id
            }
            dao.insertEntry(id, entry.skillTitle, entry.action, entry.detail, entry.at)
            box.value = id
        }
        box.value
    }

    public func list(offset: Int64, limit: Int64): ArrayList<EvolutionEntry> {
        let box = EvoListBox()
        synchronized(mutex){
            let dao = daoOf()
            ensure(dao)
            box.value = evoEntriesOf(dao.listEntries(offset, limit))
        }
        box.value
    }

    public func bySkill(skillTitle: String, limit: Int64): ArrayList<EvolutionEntry> {
        let box = EvoListBox()
        synchronized(mutex){
            let dao = daoOf()
            ensure(dao)
            box.value = evoEntriesOf(dao.listBySkill(skillTitle, limit))
        }
        box.value
    }

    private func daoOf(): PostgresEvolutionDAO {
        dao<PostgresEvolutionDAO>(DRIVER)
    }

    /** 启动时调用：建表 + 建 `bySkill` 索引（幂等） */
    public func ensureSchema(): Unit {
        synchronized(mutex){
            let dao = daoOf()
            dao.ensureTable()
            dao.ensureSkillIndex()
            tableReady = true
        }
    }

    private func ensure(dao: PostgresEvolutionDAO): Unit {
        if(tableReady){
            return
        }
        dao.ensureTable()
        dao.ensureSkillIndex()
        tableReady = true
    }

    private func maxIdOf(dao: PostgresEvolutionDAO): Int64 {
        for(row in dao.maxEntryId()){
            return evoIntOf(row.get('max_id') ?? 0)
        }
        0
    }
}

func evoEntriesOf(rows: ArrayList<HashMap<String, Any>>): ArrayList<EvolutionEntry> {
    let result = ArrayList<EvolutionEntry>()
    for(row in rows){
        result.add(EvolutionEntry(evoIntOf(row.get('id') ?? 0),
            evoTextOf(row.get('skill_title') ?? ''),
            evoTextOf(row.get('action') ?? ''),
            evoTextOf(row.get('detail') ?? ''),
            evoIntOf(row.get('at_time') ?? 0)))
    }
    result
}

func evoIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case number: Int16 => Int64(number)
        case number: Float64 => Int64(number)
        case text: String => Int64.tryParse(text) ?? 0
        case _ => 0
    }
}

func evoTextOf(value: Any): String {
    match(value){
        case text: String => text
        case number: Int64 => number.toString()
        case _ => ''
    }
}

class EvoIdBox {
    public var value: Int64 = 0
}

class EvoListBox {
    public var value: ArrayList<EvolutionEntry> = ArrayList<EvolutionEntry>()
}
