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

import fountain::f_store.Store

/**
 * f_store 元数据族（3.1）：人格持久化，不依赖任何数据库。
 *
 * key：`f_llm:meta:character:{userId}`，值：`characterKey\nprompts`。
 * 技能/提示词/配置在 3.2–3.4 补齐。
 */
public class FStoreMetaStore <: MetaStore {
    private static let CHARACTER_PREFIX = 'f_llm:meta:character:'

    private let store: Store
    private let characterStore: FStoreCharacterStore

    public init(path: String) {
        this.store = Store(path)
        this.characterStore = FStoreCharacterStore(store, CHARACTER_PREFIX)
    }

    public prop characters: CharacterStore {
        get() { characterStore }
    }
    public prop skills: SkillStore {
        get() { throw IllegalArgumentException('FStoreSkillStore not implemented (3.4)') }
    }
    public prop prompts: PromptStore {
        get() { throw IllegalArgumentException('FStorePromptStore not implemented (3.4)') }
    }
    public prop confs: LLMConfStore {
        get() { throw IllegalArgumentException('FStoreLLMConfStore not implemented (3.3)') }
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
