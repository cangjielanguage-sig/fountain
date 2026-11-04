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
 * 技能演进状态 DAO（PostgreSQL）。
 *
 * 一张表放两类数据：每技能一条状态，外加 `__run__` 一行记录整轮水位线
 * （避免为水位线单开一张表）。
 */
@DAO
public interface PostgresEvolutionStateDAO <: RootDAO {
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
            ON CONFLICT (skill_title) DO UPDATE SET
                last_evolved_at = EXCLUDED.last_evolved_at,
                gate_passed = EXCLUDED.gate_passed
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

    /**
     * 已消费的知识 docId 表：避免同一批知识每轮重复参与聚类。
     *
     * 与状态表分开建，是因为它的生命周期更长（状态会被覆盖，消费记录只增不减）。
     */
    func ensureKnowledgeTable(): Unit {
        let sql = '''
            CREATE TABLE IF NOT EXISTS llm_skill_evolution_knowledge (
              doc_id VARCHAR(255) PRIMARY KEY,
              processed_at BIGINT NOT NULL DEFAULT 0
            )
        '''
        executor.setSql(sql).update
    }

    func knowledgeList(limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT doc_id FROM llm_skill_evolution_knowledge
            ORDER BY processed_at DESC LIMIT ${arg(limit)}
        '''
        executor.setSql(sql).mapList()
    }

    func knowledgeInsert(docId: String, processedAt: Int64): Int64 {
        let sql = '''
            INSERT INTO llm_skill_evolution_knowledge (doc_id, processed_at)
            VALUES (${arg(docId)}, ${arg(processedAt)})
            ON CONFLICT (doc_id) DO NOTHING
        '''
        executor.setSql(sql).update
    }
}
