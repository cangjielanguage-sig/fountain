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
package fountain::f_llm.dao.mysql

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** 记忆种类 DAO（P1）：表结构与 PG 一致，补种用 `INSERT IGNORE` 保证幂等。 */
@DAO
public interface MySqlKindDAO <: RootDAO {
    func kindHas(kind: String): ?Map<String, Any> {
        let sql = '''
            SELECT kind FROM llm_memory_kind WHERE user_id = 0 AND kind = ${arg(kind)} LIMIT 1
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func kindInsert(kind: String, predefined: Bool, weight: Float64): Unit {
        let sql = '''
            INSERT IGNORE INTO llm_memory_kind (user_id, kind, predefined, weight)
            VALUES (0, ${arg(kind)}, ${arg(predefined)}, ${arg(weight)})
        '''
        executor.setSql(sql).update
    }
}
