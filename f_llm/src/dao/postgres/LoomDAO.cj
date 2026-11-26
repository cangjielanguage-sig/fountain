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

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** loom 流程定义 DAO（§9.9 `llm_loom_flow`） */
@DAO
public interface PostgresLoomDAO <: RootDAO {
    func loomUpsert(name: String, description: String, planJson: String, flowSource: String,
                    stepSources: String, status: String, round: Int64, questionsJson: String,
                    tools: String, mcps: String): Unit {
        let sql = '''
            INSERT INTO llm_loom_flow
                (name, description, plan_json, flow_source, step_sources, status, round,
                 questions_json, tools, mcps)
            VALUES (${arg(name)}, ${arg(description)}, ${arg(planJson)}, ${arg(flowSource)},
                    ${arg(stepSources)}, ${arg(status)}, ${arg(round)}, ${arg(questionsJson)},
                    ${arg(tools)}, ${arg(mcps)})
            ON CONFLICT (name) DO UPDATE SET
                description = EXCLUDED.description,
                plan_json = EXCLUDED.plan_json,
                flow_source = EXCLUDED.flow_source,
                step_sources = EXCLUDED.step_sources,
                status = EXCLUDED.status,
                round = EXCLUDED.round,
                questions_json = EXCLUDED.questions_json,
                tools = EXCLUDED.tools,
                mcps = EXCLUDED.mcps,
                update_time = CURRENT_TIMESTAMP
        '''
        executor.setSql(sql).update
    }

    func loomGet(name: String): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT name, description, plan_json, flow_source, step_sources, status, round,
                   questions_json, tools, mcps
            FROM llm_loom_flow WHERE name = ${arg(name)}
        '''
        executor.setSql(sql).mapList()
    }

    func loomList(offset: Int64, limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT name, description, plan_json, flow_source, step_sources, status, round,
                   questions_json, tools, mcps
            FROM llm_loom_flow ORDER BY name
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }

    func loomRemove(name: String): Unit {
        executor.setSql('DELETE FROM llm_loom_flow WHERE name = ${arg(name)}').update
    }
}
