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

/** 演进租约 DAO（PostgreSQL）：单行表，条件更新即 CAS */
@DAO
public interface PostgresEvolutionLeaseDAO <: RootDAO {
    func leaseEnsureTable(): Unit {
        let sql = '''
            CREATE TABLE IF NOT EXISTS llm_evolution_lease (
              lease_id VARCHAR(64) PRIMARY KEY,
              lease_value VARCHAR(128) NOT NULL DEFAULT ''
            )
        '''
        executor.setSql(sql).update
    }

    /** 不存在才插入；返回受影响行数（0 表示已存在） */
    func leaseInsert(leaseId: String, leaseValue: String): Int64 {
        let sql = '''
            INSERT INTO llm_evolution_lease (lease_id, lease_value)
            VALUES (${arg(leaseId)}, ${arg(leaseValue)})
            ON CONFLICT (lease_id) DO NOTHING
        '''
        executor.setSql(sql).update
    }

    func leaseRead(leaseId: String): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT lease_id, lease_value FROM llm_evolution_lease
            WHERE lease_id = ${arg(leaseId)}
        '''
        executor.setSql(sql).mapList()
    }

    /** 仅当当前值仍等于 expected 时才覆盖：返回 1 表示抢到 */
    func leaseCas(leaseId: String, expected: String, next: String): Int64 {
        let sql = '''
            UPDATE llm_evolution_lease SET lease_value = ${arg(next)}
            WHERE lease_id = ${arg(leaseId)} AND lease_value = ${arg(expected)}
        '''
        executor.setSql(sql).update
    }
}
