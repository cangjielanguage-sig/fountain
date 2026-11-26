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

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** Token 用量 DAO（P1）：MySQL 与 PG 同构。 */
@DAO
public interface MySqlTokenUsageDAO <: RootDAO {
    func usageInsert(llmId: Int64, agentId: Int64, session: String,
                     prompt: Int64, completion: Int64, total: Int64,
                     cached: Int64, usageTime: Int64): Unit {
        let sql = '''
            INSERT INTO llm_token_usage
                (llm_id, agent_id, session, prompt_tokens, completion_tokens,
                 total_tokens, cached_tokens, usage_time)
            VALUES (${arg(llmId)}, ${arg(agentId)}, ${arg(session)}, ${arg(prompt)},
                    ${arg(completion)}, ${arg(total)}, ${arg(cached)}, ${arg(usageTime)})
        '''
        executor.setSql(sql).update
    }
}
