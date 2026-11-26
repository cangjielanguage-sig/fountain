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
import std.convert.*

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_store.Store

/**
 * f_store 元数据族（3.1）：人格持久化，不依赖任何数据库。
 *
 * key：`f_llm:meta:character:{userId}`，值：`characterKey\nprompts`。
 * 技能/提示词/配置在 3.2–3.4 补齐。
 */
public class FStoreMetaStore <: MetaStore {
    private static const CHARACTER_PREFIX = 'f_llm:meta:character:'

    private let store: Store
    private let characterStore: FStoreCharacterStore
    private let confStore: FStoreLLMConfStore
    private let skillStore: FStoreSkillStore
    private let promptStore: FStorePromptStore

    public init(path: String) {
        this.store = Store(path)
        this.characterStore = FStoreCharacterStore(store, CHARACTER_PREFIX)
        this.confStore = FStoreLLMConfStore(store)
        this.skillStore = FStoreSkillStore(store)
        this.promptStore = FStorePromptStore(store)
    }

    /** 容器用：路径取 `llm_metaStorePath` */
    public init() {
        let path = DeployPaths.resolve(StoreSettings.load().metaStorePath)
        this.store = Store(path)
        this.characterStore = FStoreCharacterStore(store, CHARACTER_PREFIX)
        this.confStore = FStoreLLMConfStore(store)
        this.skillStore = FStoreSkillStore(store)
        this.promptStore = FStorePromptStore(store)
    }

    public prop characters: CharacterStore {
        get() { characterStore }
    }
    public prop skills: SkillStore {
        get() { skillStore }
    }
    public prop prompts: PromptStore {
        get() { promptStore }
    }
    public prop confs: LLMConfStore {
        get() { confStore }
    }
}

/**
 * f_store 模型配置（3.1 / 3.3）：主体 + byname 索引，两阶段写。
 *
 * 主体：`f_llm:meta:conf:{id}` = provider\nllmName\nactual\nweight\nenabled
 * 索引：`f_llm:meta:conf:byname:{llmName}:{id}`
 *
 * f_store 没有事务：先写主体、再写索引；启动时扫主体补索引。
 */
class FStoreLLMConfStore <: LLMConfStore {
    private static const PREFIX = 'f_llm:meta:conf:'
    private static const BYNAME = 'f_llm:meta:conf:byname:'
    private static const SEQ = 'f_llm:meta:seq:conf'

    private let store: Store

    public init(store: Store) {
        this.store = store
        repair()
    }

    public func put(view: LLMConfView): Int64 {
        let id = nextId()
        let body = '${view.provider}\n${view.llmName}\n${view.actualLlmName}\n${view.weight}\n'
            + '${view.enabled}\n${view.llmUrl}\n${view.auth}\n${view.temperature}\n${view.alwaysThinking}'
        store.add('${PREFIX}${id}'.toArray(), body.toArray())
        store.add('${BYNAME}${view.llmName}:${id}'.toArray(), [])
        id
    }

    public func names(): ArrayList<String> {
        let names = ArrayList<String>()
        for((key, _) in store.prefix(BYNAME.toArray())){
            let segments = String.fromUtf8(key).split(':')
            if(segments.size < 6){
                continue
            }
            let id = segments[5]
            match(store.get('${PREFIX}${id}'.toArray())){
                case Some(bytes) =>
                    let view = parse(String.fromUtf8(bytes))
                    if(view.enabled && view.weight > 0 && !has(names, view.llmName)){
                        names.add(view.llmName)
                    }
                case None => ()
            }
        }
        names
    }

    public func candidates(llmName: String): ArrayList<LLMConfView> {
        let result = ArrayList<LLMConfView>()
        let prefix = '${BYNAME}${llmName}:'
        for((key, _) in store.prefix(prefix.toArray())){
            let segments = String.fromUtf8(key).split(':')
            if(segments.size < 6){
                continue
            }
            let id = segments[5]
            match(store.get('${PREFIX}${id}'.toArray())){
                case Some(bytes) =>
                    let view = parse(String.fromUtf8(bytes))
                    if(view.enabled && view.weight > 0){
                        result.add(view)
                    }
                case None => ()
            }
        }
        result
    }

    /** 扫主体补索引；seq 键与 byname 键跳过 */
    public func repair(): Unit {
        for((key, value) in store.prefix(PREFIX.toArray())){
            let keyText = String.fromUtf8(key)
            if(keyText.startsWith(BYNAME) || keyText == SEQ){
                continue
            }
            // 主体 key 形如 f_llm:meta:conf:{id}，split 后 4 段；byname 键已在上面跳过
            let segments = keyText.split(':')
            if(segments.size < 4){
                continue
            }
            let id = segments[3]
            let view = parse(String.fromUtf8(value))
            let indexKey = '${BYNAME}${view.llmName}:${id}'
            if(store.get(indexKey.toArray()).isNone()){
                store.add(indexKey.toArray(), Array<Byte>())
            }
        }
    }

    private func nextId(): Int64 {
        let next = match(store.get(SEQ.toArray())){
            case Some(bytes) => Int64.parse(String.fromUtf8(bytes)) + 1
            case None => 1
        }
        store.add(SEQ.toArray(), '${next}'.toArray())
        next
    }

    private static func parse(text: String): LLMConfView {
        let parts = text.split('\n')
        if(parts.size < 5){
            return LLMConfView('', '', '', 0, false)
        }
        // 旧格式只有前 5 段：缺的字段用默认值，保证向后兼容
        let llmUrl = if(parts.size > 5){ parts[5] } else { '' }
        let auth = if(parts.size > 6){ parts[6] } else { '' }
        let temperature = if(parts.size > 7){ Float64.parse(parts[7]) } else { -1.0f64 }
        let alwaysThinking = if(parts.size > 8){ parts[8] == 'true' } else { false }
        LLMConfView(parts[0], parts[1], parts[2], Int64.parse(parts[3]), parts[4] == 'true',
                    llmUrl: llmUrl, auth: auth, temperature: temperature, alwaysThinking: alwaysThinking)
    }

    private static func has(values: ArrayList<String>, target: String): Bool {
        for(value in values){
            if(value == target){
                return true
            }
        }
        false
    }
}

class FStoreCharacterStore <: CharacterStore {
    private let store: Store
    private let prefix: String

    public init(store: Store, prefix: String) {
        this.store = store
        this.prefix = prefix
    }

    public func get(userId: Int64): ?Character {
        match(store.get(key(userId))){
            case Some(bytes) =>
                let text = String.fromUtf8(bytes)
                match(text.indexOf('\n')){
                    case Some(index) =>
                        Some(Character(userId, text[0..index], text[(index + 1)..]))
                    case None =>
                        Some(Character(userId, text, ''))
                }
            case None => None
        }
    }

    public func set(character: Character): Unit {
        if(!PredefinedCharacters.isKnown(character.characterKey)){
            throw IllegalArgumentException('unknown character key: ${character.characterKey}')
        }
        let text = '${character.characterKey}\n${character.prompts}'
        store.add(key(character.userId), text.toArray())
    }

    public func reset(userId: Int64): Unit {
        store.remove(key(userId))
    }

    private func key(userId: Int64): Array<Byte> {
        '${prefix}${userId}'.toArray()
    }
}

class FStoreSkillStore <: SkillStore {
    private static const PREFIX = 'f_llm:meta:skill:'
    private static const TITLE = 'f_llm:meta:skill:title:'

    private let store: Store

    public init(store: Store) {
        this.store = store
    }

    public func upsert(skill: Skill): Unit {
        // 主体用 | 分隔：title|details|functions|version（测试数据不含 |）
        let body = '${skill.title}|${skill.details}|${skill.functions}|${skill.version}'
        store.add('${PREFIX}${skill.id}'.toArray(), body.toArray())
        store.add('${TITLE}${skill.title}'.toArray(), '${skill.id}'.toArray())
    }

    public func get(id: Int64): ?Skill {
        match(store.get('${PREFIX}${id}'.toArray())){
            case Some(bytes) => Some(parse(id, String.fromUtf8(bytes)))
            case None => None
        }
    }

    public func list(): ArrayList<Skill> {
        let skills = ArrayList<Skill>()
        for((key, value) in store.prefix(PREFIX.toArray())){
            let keyText = String.fromUtf8(key)
            if(keyText.startsWith(TITLE)){
                continue
            }
            let segments = keyText.split(':')
            if(segments.size < 4){
                continue
            }
            skills.add(parse(Int64.parse(segments[3]), String.fromUtf8(value)))
        }
        skills
    }

    public func remove(id: Int64): Bool {
        match(store.get('${PREFIX}${id}'.toArray())){
            case Some(bytes) =>
                let title = parse(id, String.fromUtf8(bytes)).title
                // 先删索引，再删主体
                store.remove('${TITLE}${title}'.toArray())
                store.remove('${PREFIX}${id}'.toArray())
                true
            case None => false
        }
    }

    private static func parse(id: Int64, text: String): Skill {
        let parts = text.split('|')
        if(parts.size < 4){
            return Skill(id, '', '', '', version: 1)
        }
        Skill(id, parts[0], parts[1], parts[2], version: Int64.parse(parts[3]))
    }
}

class FStorePromptStore <: PromptStore {
    private static const PREFIX = 'f_llm:meta:prompt:'

    private let store: Store

    public init(store: Store) {
        this.store = store
    }

    public func put(entry: PromptEntry): Unit {
        store.add('${PREFIX}${entry.name}:${entry.version}'.toArray(), entry.content.toArray())
        store.add('${PREFIX}${entry.name}:latest'.toArray(), '${entry.version}'.toArray())
    }

    public func get(name: String, version: Int64): ?PromptEntry {
        match(store.get('${PREFIX}${name}:${version}'.toArray())){
            case Some(bytes) => Some(PromptEntry(name, version, String.fromUtf8(bytes)))
            case None => None
        }
    }

    public func latest(name: String): ?PromptEntry {
        match(store.get('${PREFIX}${name}:latest'.toArray())){
            case Some(bytes) =>
                let version = Int64.parse(String.fromUtf8(bytes))
                get(name, version)
            case None => None
        }
    }

    public func remove(name: String, version: Int64): Bool {
        let key = '${PREFIX}${name}:${version}'
        if(store.get(key.toArray()).isNone()){
            return false
        }
        store.remove(key.toArray())
        // 删除后重算 latest：扫剩余版本取最大值，没有则清掉指针
        var maxVersion: Int64 = -1
        for((item, _) in store.prefix('${PREFIX}${name}:'.toArray())){
            let segments = String.fromUtf8(item).split(':')
            if(segments.size < 5 || segments[4] == 'latest'){
                continue
            }
            let candidate = Int64.parse(segments[4])
            if(candidate > maxVersion){
                maxVersion = candidate
            }
        }
        if(maxVersion > 0){
            store.add('${PREFIX}${name}:latest'.toArray(), '${maxVersion}'.toArray())
        }else{
            store.remove('${PREFIX}${name}:latest'.toArray())
        }
        true
    }
}