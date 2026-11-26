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

/** MySQL 版演进租约：单行表 + 条件更新（CAS），语义与 PG 版一致 */
public class MySqlEvolutionLease <: EvolutionLease & RootService {
    private static let DRIVER = 'mysql'
    private static let ROW = 'evolution'

    private let mutex = Mutex()
    private var ready = false

    public init() {
    }

    public func ensureSchema(): Unit {
        synchronized(mutex){
            ensureReady()
        }
    }

    public func ensure(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            ensureReady()
            if(read().isEmpty()){
                let created = TimeUuid.create()
                let _ = daoOf().leaseInsert(ROW, created)
            }
            box.value = read()
        }
        box.value
    }

    public func current(): String {
        let box = LeaseBox()
        synchronized(mutex){
            ensureReady()
            box.value = read()
        }
        box.value
    }

    public func acquire(now: Int64): String {
        let box = LeaseBox()
        synchronized(mutex){
            ensureReady()
            let previous = read()
            if(previous.isEmpty()){
                let created = TimeUuid.create()
                if(daoOf().leaseInsert(ROW, created) == 1){
                    box.value = created
                }
            }else if(TimeUuid.dayOf(previous) != now / 86400){
                let created = TimeUuid.create()
                if(daoOf().leaseCas(ROW, previous, created) == 1){
                    box.value = created
                }
            }
        }
        box.value
    }

    private func ensureReady(): Unit {
        if(!ready){
            daoOf().leaseEnsureTable()
            ready = true
        }
    }

    private func read(): String {
        for(row in daoOf().leaseRead(ROW)){
            return myLeaseTextOf(row.get('lease_value') ?? '')
        }
        ''
    }

    private func daoOf(): MySqlEvolutionLeaseDAO {
        dao<MySqlEvolutionLeaseDAO>(DRIVER)
    }
}

private func myLeaseTextOf(value: Any): String {
    match(value){
        case text: String => text
        case _ => ''
    }
}

class LeaseBox {
    public var value: String = ''
}
