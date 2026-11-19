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

/** MySQL 元数据族 DAO：方言差异（ON DUPLICATE KEY / LAST_INSERT_ID / TINYINT）集中在此。 */
@DAO
public interface MySqlMetaDAO <: RootDAO {
    func characterGet(userId: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT character_key, prompts FROM llm_character WHERE user_id = ${arg(userId)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func characterUpsert(userId: Int64, key: String, prompts: String): Unit {
        let sql = '''
            INSERT INTO llm_character (user_id, character_key, prompts, update_time)
            VALUES (${arg(userId)}, ${arg(key)}, ${arg(prompts)}, UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                character_key = VALUES(character_key),
                prompts = VALUES(prompts),
                update_time = UTC_TIMESTAMP()
        '''
        executor.setSql(sql).update
    }

    func characterDelete(userId: Int64): Unit {
        let sql = 'DELETE FROM llm_character WHERE user_id = ${arg(userId)}'
        executor.setSql(sql).update
        ()
    }

    func confNames(): ArrayList<String> {
        let rows = executor.setSql(
            'SELECT DISTINCT llm_name FROM llm_conf WHERE enabled = 1 AND weight > 0'
        ).mapList()
        let names = ArrayList<String>()
        for(row in rows){
            names.add(text(row.get('llm_name')))
        }
        names
    }

    func confCandidates(llmName: String): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT provider, llm_name, actual_llm_name, weight,
                   llm_url, auth, temperature, CAST(always_thinking AS SIGNED) AS always_thinking
            FROM llm_conf
            WHERE enabled = 1 AND weight > 0 AND llm_name = ${arg(llmName)}
        '''
        executor.setSql(sql).mapList()
    }

    func confPut(provider: String, llmName: String, actualLlmName: String, enabled: Bool,
                 weight: Int64, llmUrl: String, auth: String, temperature: Float64,
                 alwaysThinking: Bool): Int64 {
        let sql = '''
            INSERT INTO llm_conf (provider, llm_name, actual_llm_name, enabled, weight,
                                  llm_url, auth, temperature, always_thinking)
            VALUES (${arg(provider)}, ${arg(llmName)}, ${arg(actualLlmName)}, ${arg(enabled)},
                    ${arg(weight)}, ${arg(llmUrl)}, ${arg(auth)}, ${arg(temperature)},
                    ${arg(alwaysThinking)})
        '''
        executor.setSql(sql).update
        let row = executor.setSql('SELECT CAST(LAST_INSERT_ID() AS SIGNED) AS id').firstToMap()
        match(row.get('id')){
            case Some(value: Int64) => value
            case Some(value: Int32) => Int64(value)
            case _ => 0
        }
    }

    func skillUpsert(id: Int64, title: String, details: String, functions: String,
                     version: Int64): Unit {
        let sql = '''
            INSERT INTO skills (id, title, details, functions, version)
            VALUES (${arg(id)}, ${arg(title)}, ${arg(details)}, ${arg(functions)}, ${arg(version)})
            ON DUPLICATE KEY UPDATE
                title = VALUES(title), details = VALUES(details),
                functions = VALUES(functions), version = VALUES(version)
        '''
        executor.setSql(sql).update
    }

    func skillGet(id: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT title, details, functions, version FROM skills WHERE id = ${arg(id)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func skillList(): ArrayList<HashMap<String, Any>> {
        executor.setSql('SELECT id, title, details, functions, version FROM skills ORDER BY id').mapList()
    }

    func skillDelete(id: Int64): Int64 {
        let sql = 'DELETE FROM skills WHERE id = ${arg(id)}'
        let deleted = executor.setSql(sql).update
        deleted
    }

    func promptPut(name: String, version: Int64, content: String): Unit {
        let sql = '''
            INSERT INTO llm_prompt (name, version, content, update_time)
            VALUES (${arg(name)}, ${arg(version)}, ${arg(content)}, UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE content = VALUES(content), update_time = UTC_TIMESTAMP()
        '''
        executor.setSql(sql).update
    }

    func promptGet(name: String, version: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT content FROM llm_prompt WHERE name = ${arg(name)} AND version = ${arg(version)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func promptLatest(name: String): ?Map<String, Any> {
        let sql = '''
            SELECT version, content FROM llm_prompt WHERE name = ${arg(name)}
            ORDER BY version DESC LIMIT 1
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func promptDelete(name: String, version: Int64): Int64 {
        let sql = 'DELETE FROM llm_prompt WHERE name = ${arg(name)} AND version = ${arg(version)}'
        let deleted = executor.setSql(sql).update
        deleted
    }
}

private func text(value: ?Any): String {
    match(value){
        case Some(raw) =>
            match(raw){
                case text: String => text
                case _ => ''
            }
        case None => ''
    }
}
