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
package fountain::f_llm.store.mysql

import std.collection.*

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_orm.*

import fountain::f_llm.dao.mysql.*
import fountain::f_llm.store.*

/** MySQL 元数据族：SQL 在 `MySqlMetaDAO`，实现 `RootService` 取执行器。 */
@Bean
@BeanMeta[condition: ConfCond.Value('llm_metaStore', StringCond.Exactly('mysql'))]
public class MySqlMetaStore <: MetaStore & RootService {
    public init() {
    }

    public prop characters: CharacterStore {
        get() { MySqlCharacterStore() }
    }
    public prop skills: SkillStore {
        get() { MySqlSkillStore() }
    }
    public prop prompts: PromptStore {
        get() { MySqlPromptStore() }
    }
    public prop confs: LLMConfStore {
        get() { MySqlLLMConfStore() }
    }
}

class MySqlCharacterStore <: CharacterStore & RootService {
    public func get(userId: Int64): ?Character {
        match(dao<MySqlMetaDAO>('mysql').characterGet(userId)){
            case Some(row) =>
                Some(Character(userId, textOf(row.get('character_key'), 'default'),
                               textOf(row.get('prompts'), '')))
            case None => None
        }
    }

    public func set(character: Character): Unit {
        if(!PredefinedCharacters.isKnown(character.characterKey)){
            throw IllegalArgumentException('unknown character key: ${character.characterKey}')
        }
        dao<MySqlMetaDAO>('mysql').characterUpsert(character.userId, character.characterKey,
                                                   character.prompts)
    }

    public func reset(userId: Int64): Unit {
        dao<MySqlMetaDAO>('mysql').characterDelete(userId)
    }
}

class MySqlSkillStore <: SkillStore & RootService {
    public func upsert(skill: Skill): Unit {
        dao<MySqlMetaDAO>('mysql').skillUpsert(skill.id, skill.title, skill.details,
                                               skill.functions, skill.version)
    }

    public func get(id: Int64): ?Skill {
        match(dao<MySqlMetaDAO>('mysql').skillGet(id)){
            case Some(row) =>
                Some(Skill(id, textOf(row.get('title'), ''), textOf(row.get('details'), ''),
                           textOf(row.get('functions'), ''), version: intOf(row.get('version'))))
            case None => None
        }
    }

    public func list(): ArrayList<Skill> {
        let skills = ArrayList<Skill>()
        for(row in dao<MySqlMetaDAO>('mysql').skillList()){
            skills.add(Skill(intOf(row.get('id')), textOf(row.get('title'), ''),
                             textOf(row.get('details'), ''), textOf(row.get('functions'), ''),
                             version: intOf(row.get('version'))))
        }
        skills
    }

    public func remove(id: Int64): Bool {
        dao<MySqlMetaDAO>('mysql').skillDelete(id) > 0
    }
}

class MySqlPromptStore <: PromptStore & RootService {
    public func put(entry: PromptEntry): Unit {
        dao<MySqlMetaDAO>('mysql').promptPut(entry.name, entry.version, entry.content)
    }

    public func get(name: String, version: Int64): ?PromptEntry {
        match(dao<MySqlMetaDAO>('mysql').promptGet(name, version)){
            case Some(row) => Some(PromptEntry(name, version, textOf(row.get('content'), '')))
            case None => None
        }
    }

    public func latest(name: String): ?PromptEntry {
        match(dao<MySqlMetaDAO>('mysql').promptLatest(name)){
            case Some(row) =>
                Some(PromptEntry(name, intOf(row.get('version')), textOf(row.get('content'), '')))
            case None => None
        }
    }

    public func remove(name: String, version: Int64): Bool {
        dao<MySqlMetaDAO>('mysql').promptDelete(name, version) > 0
    }
}

class MySqlLLMConfStore <: LLMConfStore & RootService {
    public func names(): ArrayList<String> {
        dao<MySqlMetaDAO>('mysql').confNames()
    }

    public func candidates(llmName: String): ArrayList<LLMConfView> {
        let result = ArrayList<LLMConfView>()
        for(row in dao<MySqlMetaDAO>('mysql').confCandidates(llmName)){
            result.add(LLMConfView(
                textOf(row.get('provider'), ''),
                textOf(row.get('llm_name'), ''),
                textOf(row.get('actual_llm_name'), ''),
                intOf(row.get('weight')),
                true,
                llmUrl: textOf(row.get('llm_url'), ''),
                auth: textOf(row.get('auth'), ''),
                temperature: floatOf(row.get('temperature')),
                alwaysThinking: boolOf(row.get('always_thinking'))
            ))
        }
        result
    }

    public func put(view: LLMConfView): Int64 {
        dao<MySqlMetaDAO>('mysql').confPut(view.provider, view.llmName, view.actualLlmName,
                                          view.enabled, view.weight, view.llmUrl, view.auth,
                                          view.temperature, view.alwaysThinking)
    }
}

private func textOf(value: ?Any, fallback: String): String {
    match(value){
        case Some(raw) =>
            match(raw){
                case text: String => text
                case _ => fallback
            }
        case None => fallback
    }
}

private func intOf(value: ?Any): Int64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Int64 => number
                case number: Int32 => Int64(number)
                case number: Int16 => Int64(number)
                case _ => 0
            }
        case None => 0
    }
}

private func floatOf(value: ?Any): Float64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Float64 => number
                case number: Float32 => Float64(number)
                case number: Int64 => Float64(number)
                case _ => -1.0f64
            }
        case None => -1.0f64
    }
}

private func boolOf(value: ?Any): Bool {
    match(value){
        case Some(raw) =>
            match(raw){
                case flag: Bool => flag
                case number: Int64 => number != 0
                case _ => false
            }
        case None => false
    }
}
