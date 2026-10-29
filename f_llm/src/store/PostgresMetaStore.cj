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
package fountain::f_llm.store

import std.collection.*

import fountain::f_orm.*

/**
 * PostgreSQL 元数据族（3.2）：先落人格，技能/提示词/配置在 3.3–3.4 补。
 */
public class PostgresMetaStore <: MetaStore {
    private let characterStore: PostgresCharacterStore
    private let confStore: PostgresLLMConfStore

    public init(executor: SqlExecutor) {
        this.characterStore = PostgresCharacterStore(executor)
        this.confStore = PostgresLLMConfStore(executor)
    }

    public prop characters: CharacterStore {
        get() { characterStore }
    }
    public prop skills: SkillStore {
        get() { throw IllegalArgumentException('PostgresSkillStore not implemented (3.4)') }
    }
    public prop prompts: PromptStore {
        get() { throw IllegalArgumentException('PostgresPromptStore not implemented (3.4)') }
    }
    public prop confs: LLMConfStore {
        get() { confStore }
    }
}

class PostgresLLMConfStore <: LLMConfStore {
    private let executor: SqlExecutor

    public init(executor: SqlExecutor) {
        this.executor = executor
    }

    public func names(): ArrayList<String> {
        let names = ArrayList<String>()
        for(row in executor.setSql(
            'SELECT DISTINCT llm_name FROM llm_conf WHERE enabled = true AND weight > 0'
        ).mapList()){
            names.add(textOf(row.get('llm_name') ?? ''))
        }
        names
    }

    public func candidates(llmName: String): ArrayList<LLMConfView> {
        let result = ArrayList<LLMConfView>()
        for(row in executor.setSql('''
            SELECT provider, llm_name, actual_llm_name, weight, enabled
            FROM llm_conf
            WHERE enabled = true AND weight > 0 AND llm_name = ?
        ''').add(llmName).mapList()){
            result.add(LLMConfView(
                textOf(row.get('provider') ?? ''),
                textOf(row.get('llm_name') ?? ''),
                textOf(row.get('actual_llm_name') ?? ''),
                intOf(row.get('weight') ?? 0),
                true
            ))
        }
        result
    }

    public func put(view: LLMConfView): Int64 {
        let row = executor.setSql('''
            INSERT INTO llm_conf (provider, llm_name, actual_llm_name, enabled, weight)
            VALUES (?, ?, ?, ?, ?)
            RETURNING id
        ''')
            .add(view.provider)
            .add(view.llmName)
            .add(view.actualLlmName)
            .add(view.enabled)
            .add(view.weight)
            .firstToMap()
        intOf(row.get('id') ?? 0)
    }

    private static func textOf(value: Any): String {
        match(value){
            case text: String => text
            case _ => ''
        }
    }

    private static func intOf(value: Any): Int64 {
        match(value){
            case number: Int64 => number
            case number: Int32 => Int64(number)
            case _ => 0
        }
    }
}

class PostgresCharacterStore <: CharacterStore {
    private let executor: SqlExecutor

    public init(executor: SqlExecutor) {
        this.executor = executor
    }

    public func get(userId: Int64): ?Character {
        let row = executor.setSql(
            'SELECT character_key, prompts FROM llm_character WHERE user_id = ?'
        ).add(userId).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some(Character(userId,
                textOf(row.get('character_key') ?? 'default'),
                textOf(row.get('prompts') ?? '')))
        }
    }

    public func set(character: Character): Unit {
        if(!PredefinedCharacters.isKnown(character.characterKey)){
            throw IllegalArgumentException('unknown character key: ${character.characterKey}')
        }
        executor.setSql('''
            INSERT INTO llm_character (user_id, character_key, prompts, update_time)
            VALUES (?, ?, ?, now())
            ON CONFLICT (user_id)
            DO UPDATE SET character_key = EXCLUDED.character_key,
                          prompts = EXCLUDED.prompts,
                          update_time = now()
        ''')
            .add(character.userId)
            .add(character.characterKey)
            .add(character.prompts)
            .update
    }

    public func reset(userId: Int64): Unit {
        executor.setSql('DELETE FROM llm_character WHERE user_id = ?').add(userId).delete
    }

    private static func textOf(value: Any): String {
        match(value){
            case text: String => text
            case _ => ''
        }
    }
}
