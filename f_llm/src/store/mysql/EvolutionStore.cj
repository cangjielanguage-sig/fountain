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

/**
 * MySQL 版演进报告表。
 *
 * 与 PG 版同构：`id` 由本类分配（`MAX(id)+1`），不依赖自增列与 `LAST_INSERT_ID()`。
 */
public class MySqlEvolutionStore <: EvolutionStore & RootService {
    private static let DRIVER = 'mysql'

    private let mutex = Mutex()
    private var tableReady = false
    private var nextId: Int64 = 0

    public init() {
    }

    public func save(entry: EvolutionEntry): Int64 {
        let box = MyEvoIdBox()
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
        let box = MyEvoListBox()
        synchronized(mutex){
            let dao = daoOf()
            ensure(dao)
            box.value = myEvoEntriesOf(dao.listEntries(offset, limit))
        }
        box.value
    }

    public func bySkill(skillTitle: String, limit: Int64): ArrayList<EvolutionEntry> {
        let box = MyEvoListBox()
        synchronized(mutex){
            let dao = daoOf()
            ensure(dao)
            box.value = myEvoEntriesOf(dao.listBySkill(skillTitle, limit))
        }
        box.value
    }

    private func daoOf(): MySqlEvolutionDAO {
        dao<MySqlEvolutionDAO>(DRIVER)
    }

    /** 启动时调用：建表（索引随 DDL 一起建，幂等） */
    public func ensureSchema(): Unit {
        synchronized(mutex){
            let dao = daoOf()
            dao.ensureTable()
            tableReady = true
        }
    }

    private func ensure(dao: MySqlEvolutionDAO): Unit {
        if(tableReady){
            return
        }
        dao.ensureTable()
        tableReady = true
    }

    private func maxIdOf(dao: MySqlEvolutionDAO): Int64 {
        for(row in dao.maxEntryId()){
            return myEvoIntOf(row.get('max_id') ?? 0)
        }
        0
    }
}

func myEvoEntriesOf(rows: ArrayList<HashMap<String, Any>>): ArrayList<EvolutionEntry> {
    let result = ArrayList<EvolutionEntry>()
    for(row in rows){
        result.add(EvolutionEntry(myEvoIntOf(row.get('id') ?? 0),
            myEvoTextOf(row.get('skill_title') ?? ''),
            myEvoTextOf(row.get('action') ?? ''),
            myEvoTextOf(row.get('detail') ?? ''),
            myEvoIntOf(row.get('at_time') ?? 0)))
    }
    result
}

func myEvoIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case number: Int16 => Int64(number)
        case number: Float64 => Int64(number)
        case text: String => Int64.tryParse(text) ?? 0
        case _ => 0
    }
}

func myEvoTextOf(value: Any): String {
    match(value){
        case text: String => text
        case number: Int64 => number.toString()
        case _ => ''
    }
}

class MyEvoIdBox {
    public var value: Int64 = 0
}

class MyEvoListBox {
    public var value: ArrayList<EvolutionEntry> = ArrayList<EvolutionEntry>()
}
