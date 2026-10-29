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

import std.collection.ArrayList

/**
 * 内容族：记忆、经验、知识、文档。
 *
 * 调用方只依赖这两个属性，不感知后端是 PostgreSQL、MySQL 还是 fhydra。
 */
public interface ContentStore {
    prop memory: MemoryStore
    prop knowledge: KnowledgeStore
}

/**
 * 元数据族：人格、技能、提示词、模型配置。
 */
public interface MetaStore {
    prop characters: CharacterStore
    prop skills: SkillStore
    prop prompts: PromptStore
    prop confs: LLMConfStore
}

/** 记忆与经验（经验用 kind=task/knowledge 表达，不另开接口） */
public interface MemoryStore {
    func add(write: MemoryWrite): MemoryRecord
    func get(userId: Int64, id: Int64): ?MemoryRecord
    func remove(userId: Int64, id: Int64): Bool
    func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord>
    func search(query: MemoryQuery): ArrayList<MemoryHit>
}

/** 知识与文档（按文档/块组织） */
public interface KnowledgeStore {
    func upsert(doc: KnowledgeDoc): Unit
    func get(docId: String): ?KnowledgeDoc
    func remove(docId: String): Bool
}

/** 人格：一个用户至多一条 */
public interface CharacterStore {
    func get(userId: Int64): ?Character
    func set(character: Character): Unit
    func reset(userId: Int64): Unit
}

/** 技能 */
public interface SkillStore {
    func upsert(skill: Skill): Unit
    func get(id: Int64): ?Skill
    func list(): ArrayList<Skill>
}

/** 提示词（按 name + version 存，保留最新指针） */
public interface PromptStore {
    func put(entry: PromptEntry): Unit
    func get(name: String, version: Int64): ?PromptEntry
    func latest(name: String): ?PromptEntry
}

/** 模型配置：1.2 先保留最小的名字查询，3.3 再补候选过滤 */
public interface LLMConfStore {
    func names(): ArrayList<String>
    /** 候选：enabled=true 且 weight>0，按 llmName 过滤（3.3） */
    func candidates(llmName: String): ArrayList<LLMConfView>
    /** 新增/覆盖一条配置，返回 id；f_store 用它落 byname 索引（3.3） */
    func put(view: LLMConfView): Int64
}
