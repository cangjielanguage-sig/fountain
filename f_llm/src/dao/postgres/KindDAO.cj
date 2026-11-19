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
package fountain::f_llm.dao.postgres

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

/**
 * 记忆种类 DAO（P1）：预定义 kind 统一挂在 `user_id = 0`。
 *
 * 表结构沿用 `tables-pg.sql` 里已有的 `llm_memory_kind(user_id, kind, predefined, weight)`，
 * 主键是 `(user_id, kind)`，因此补种用 `ON CONFLICT (user_id, kind) DO NOTHING`。
 */
@DAO
public interface PostgresKindDAO <: RootDAO {
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
            INSERT INTO llm_memory_kind (user_id, kind, predefined, weight)
            VALUES (0, ${arg(kind)}, ${arg(predefined)}, ${arg(weight)})
            ON CONFLICT (user_id, kind) DO NOTHING
        '''
        executor.setSql(sql).update
    }

    func kindAllCustom(): ArrayList<HashMap<String, Any>> {
        executor.setSql(
            'SELECT user_id, kind FROM llm_memory_kind WHERE predefined = false ORDER BY user_id, kind'
        ).mapList()
    }

    func kindInsertCustom(userId: Int64, kind: String, weight: Float64): Unit {
        let sql = '''
            INSERT INTO llm_memory_kind (user_id, kind, predefined, weight)
            VALUES (${arg(userId)}, ${arg(kind)}, false, ${arg(weight)})
            ON CONFLICT (user_id, kind) DO NOTHING
        '''
        executor.setSql(sql).update
    }

    func kindDeleteCustom(userId: Int64, kind: String): Int64 {
        let sql = '''
            DELETE FROM llm_memory_kind
            WHERE user_id = ${arg(userId)} AND kind = ${arg(kind)} AND predefined = false
        '''
        let deleted = executor.setSql(sql).update
        deleted
    }
}
