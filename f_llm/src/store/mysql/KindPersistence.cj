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

import fountain::f_orm.*

import fountain::f_llm.dao.mysql.*
import fountain::f_llm.store.*

/** MySQL 记忆种类持久化（P1）。 */
public class MySqlKindPersistence <: KindPersistence & RootService {
    public init() {
    }

    public func has(kind: String): Bool {
        dao<MySqlKindDAO>('mysql').kindHas(kind).isSome()
    }

    public func insert(kind: String, predefined: Bool): Unit {
        dao<MySqlKindDAO>('mysql').kindInsert(kind, predefined, MemoryKinds.weightOf(kind))
    }

    public func allCustom(): HashMap<Int64, ArrayList<String>> {
        let result = HashMap<Int64, ArrayList<String>>()
        for(row in dao<MySqlKindDAO>('mysql').kindAllCustom()){
            let userId = kindIntOf(row.get('user_id'))
            let kind = kindTextOf(row.get('kind'))
            if(kind.isEmpty()){
                continue
            }
            match(result.get(userId)){
                case Some(kinds) => kinds.add(kind)
                case None =>
                    let kinds = ArrayList<String>()
                    kinds.add(kind)
                    result[userId] = kinds
            }
        }
        result
    }

    public func insertCustom(userId: Int64, kind: String): Unit {
        dao<MySqlKindDAO>('mysql').kindInsertCustom(userId, kind, MemoryKinds.weightOf(kind))
    }

    public func deleteCustom(userId: Int64, kind: String): Unit {
        dao<MySqlKindDAO>('mysql').kindDeleteCustom(userId, kind)
        ()
    }
}

private func kindTextOf(value: ?Any): String {
    match(value){
        case Some(raw) =>
            match(raw){
                case text: String => text
                case _ => ''
            }
        case None => ''
    }
}

private func kindIntOf(value: ?Any): Int64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Int64 => number
                case number: Int32 => Int64(number)
                case _ => 0
            }
        case None => 0
    }
}
