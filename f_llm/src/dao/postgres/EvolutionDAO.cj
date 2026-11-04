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

/** 技能演进报告 DAO（PostgreSQL）：`llm_skill_evolution` 只追加不更新 */
@DAO
public interface PostgresEvolutionDAO <: RootDAO {
    func ensureTable(): Unit {
        let sql = '''
            CREATE TABLE IF NOT EXISTS llm_skill_evolution (
              id BIGINT PRIMARY KEY,
              skill_title VARCHAR(128) NOT NULL,
              action VARCHAR(32) NOT NULL,
              detail TEXT,
              at_time BIGINT NOT NULL DEFAULT 0
            )
        '''
        executor.setSql(sql).update
    }

    func insertEntry(id: Int64, skillTitle: String, action: String,
                     detail: String, atTime: Int64): Unit {
        let sql = '''
            INSERT INTO llm_skill_evolution (id, skill_title, action, detail, at_time)
            VALUES (${arg(id)}, ${arg(skillTitle)}, ${arg(action)}, ${arg(detail)}, ${arg(atTime)})
        '''
        executor.setSql(sql).update
    }

    func listEntries(offset: Int64, limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT id, skill_title, action, detail, at_time FROM llm_skill_evolution
            ORDER BY at_time DESC, id DESC
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }

    func listBySkill(skillTitle: String, limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT id, skill_title, action, detail, at_time FROM llm_skill_evolution
            WHERE skill_title = ${arg(skillTitle)}
            ORDER BY at_time DESC, id DESC
            LIMIT ${arg(limit)}
        '''
        executor.setSql(sql).mapList()
    }

    func maxEntryId(): ArrayList<HashMap<String, Any>> {
        let sql = 'SELECT COALESCE(MAX(id), 0) AS max_id FROM llm_skill_evolution'
        executor.setSql(sql).mapList()
    }
}
