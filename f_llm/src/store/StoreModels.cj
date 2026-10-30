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
import std.time.DateTime

/** 一条记忆（读模型） */
public class MemoryRecord {
    public let id: Int64
    public let userId: Int64
    public let namespace: String
    public let title: String
    public let content: String
    public let kind: String
    public let saveTime: DateTime

    public init(id: Int64, userId: Int64, namespace: String, title: String,
                content: String, kind: String, saveTime: DateTime) {
        this.id = id
        this.userId = userId
        this.namespace = namespace
        this.title = title
        this.content = content
        this.kind = kind
        this.saveTime = saveTime
    }
}

/** 写入请求（不包含 id / saveTime，由存储分配） */
public class MemoryWrite {
    public let userId: Int64
    public let namespace: String
    public let title: String
    public let content: String
    public let kind: String

    public init(userId: Int64, namespace: String, title: String, content: String, kind: String) {
        this.userId = userId
        this.namespace = namespace
        this.title = title
        this.content = content
        this.kind = kind
    }
}

/** 检索请求 */
public class MemoryQuery {
    public let userId: Int64
    public let namespaces: Array<String>
    public let kinds: Array<String>
    public let text: String
    public let topK: Int64
    /** true 时对候选做 colbert 重排（只改排序，不改候选集） */
    public let rerank: Bool

    public init(userId: Int64, namespaces: Array<String>, kinds: Array<String>,
                text: String, topK!: Int64 = 5, rerank!: Bool = false) {
        this.userId = userId
        this.namespaces = namespaces
        this.kinds = kinds
        this.text = text
        this.topK = topK
        this.rerank = rerank
    }
}

/** 检索命中 */
public class MemoryHit {
    public let record: MemoryRecord
    public let score: Float64
    /** true 表示该次检索缺了某一路（当前是 sparse 缺失），分数只由剩余通路融合 */
    public let degraded: Bool

    public init(record: MemoryRecord, score: Float64, degraded!: Bool = false) {
        this.record = record
        this.score = score
        this.degraded = degraded
    }
}

/** 人格记录（一人一条） */
public class Character {
    public let userId: Int64
    public let characterKey: String
    public let prompts: String

    public init(userId: Int64, characterKey: String, prompts: String) {
        this.userId = userId
        this.characterKey = characterKey
        this.prompts = prompts
    }
}

/** 技能记录（1.2 只保留契约所需字段） */
public class Skill {
    public let id: Int64
    public let title: String
    public let details: String
    public let functions: String
    public let version: Int64

    public init(id: Int64, title: String, details: String, functions: String, version!: Int64 = 1) {
        this.id = id
        this.title = title
        this.details = details
        this.functions = functions
        this.version = version
    }
}

/** 提示词版本 */
public class PromptEntry {
    public let name: String
    public let version: Int64
    public let content: String

    public init(name: String, version: Int64, content: String) {
        this.name = name
        this.version = version
        this.content = content
    }
}

/** colbert 多头向量：每个 token 一个向量，重排时做 max-sim */
public class ColbertVectors {
    public let title: Array<Array<Float64>>
    public let content: Array<Array<Float64>>

    public init(title: Array<Array<Float64>>, content: Array<Array<Float64>>) {
        this.title = title
        this.content = content
    }
}

/** 知识/文档块 */
public class KnowledgeDoc {
    public let docId: String
    public let title: String
    public let content: String

    public init(docId: String, title: String, content: String) {
        this.docId = docId
        this.title = title
        this.content = content
    }
}

/** 空实现辅助：让接口先能编译 */
public func emptySkills(): ArrayList<Skill> {
    ArrayList<Skill>()
}

/** 模型配置的存储视图（3.3）：只保留检索/选型需要的字段 */
public class LLMConfView {
    public let provider: String
    public let llmName: String
    public let actualLlmName: String
    public let weight: Int64
    public let enabled: Bool
    /** 以下为完整配置字段（1.x）：构造 LLMConf 需要 */
    public let llmUrl: String
    public let auth: String
    public let temperature: Float64
    public let alwaysThinking: Bool

    public init(provider: String, llmName: String, actualLlmName: String, weight: Int64, enabled: Bool,
                llmUrl!: String = '', auth!: String = '', temperature!: Float64 = -1.0f64,
                alwaysThinking!: Bool = false) {
        this.provider = provider
        this.llmName = llmName
        this.actualLlmName = actualLlmName
        this.weight = weight
        this.enabled = enabled
        this.llmUrl = llmUrl
        this.auth = auth
        this.temperature = temperature
        this.alwaysThinking = alwaysThinking
    }
}