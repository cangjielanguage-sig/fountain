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
 * PostgreSQL 版演进租约：单行表 + 条件更新（CAS）。
 *
 * 多进程同时到点触发时，只有 `leaseCas` 影响行数为 1 的那个进程继续执行，
 * 其余进程拿到空串直接放弃。
 */
public class PostgresEvolutionLease <: EvolutionLease & RootService {
    private static let DRIVER = 'postgres'
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
                // 租约还没建：插入成功即抢到
                let created = TimeUuid.create()
                if(daoOf().leaseInsert(ROW, created) == 1){
                    box.value = created
                }
            }else if(TimeUuid.dayOf(previous) != now / 86400){
                // 上次执行不是今天：CAS 覆盖，别人先改就失败
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
            return pgLeaseTextOf(row.get('lease_value') ?? '')
        }
        ''
    }

    private func daoOf(): PostgresEvolutionLeaseDAO {
        dao<PostgresEvolutionLeaseDAO>(DRIVER)
    }
}

private func pgLeaseTextOf(value: Any): String {
    match(value){
        case text: String => text
        case _ => ''
    }
}

class LeaseBox {
    public var value: String = ''
}
