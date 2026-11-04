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

/** 技能演进状态 DAO（MySQL）：每技能一条 + `__run__` 水位线 */
@DAO
public interface MySqlEvolutionStateDAO <: RootDAO {
    func ensureStateTable(): Unit {
        let sql = '''
            CREATE TABLE IF NOT EXISTS llm_skill_evolution_state (
              skill_title VARCHAR(128) PRIMARY KEY,
              last_evolved_at BIGINT NOT NULL DEFAULT 0,
              gate_passed INT NOT NULL DEFAULT 0
            )
        '''
        executor.setSql(sql).update
    }

    func upsertState(skillTitle: String, lastEvolvedAt: Int64, gatePassed: Int64): Unit {
        let sql = '''
            INSERT INTO llm_skill_evolution_state (skill_title, last_evolved_at, gate_passed)
            VALUES (${arg(skillTitle)}, ${arg(lastEvolvedAt)}, ${arg(gatePassed)})
            ON DUPLICATE KEY UPDATE
                last_evolved_at = VALUES(last_evolved_at),
                gate_passed = VALUES(gate_passed)
        '''
        executor.setSql(sql).update
    }

    func getState(skillTitle: String): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT skill_title, last_evolved_at, gate_passed
            FROM llm_skill_evolution_state WHERE skill_title = ${arg(skillTitle)}
        '''
        executor.setSql(sql).mapList()
    }
}
