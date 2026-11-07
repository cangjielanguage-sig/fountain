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

/**
 * 检索打分的唯一来源。
 *
 * 之前这套公式在 `postgres/KnowledgeStore`、`mysql/KnowledgeStore`、`InMemoryStores`、
 * `PostgresMemoryStore` 各写了一遍（有的还是裸数字），改权重得改四处、且随时可能漂移。
 * 这里把常量与算式收口成一份，各后端只负责取候选。
 */
public class RetrievalScoring {
    private init() {
    }

    /** 记忆：向量相似度权重 */
    public static let MEMORY_DENSE_WEIGHT: Float64 = 0.7f64
    /** 记忆：倒排（sparse）权重 */
    public static let MEMORY_SPARSE_WEIGHT: Float64 = 0.3f64
    /** 记忆重排：标题相似度权重 */
    public static let RERANK_TITLE_WEIGHT: Float64 = 0.4f64
    /** 记忆重排：正文相似度权重 */
    public static let RERANK_CONTENT_WEIGHT: Float64 = 0.6f64
    /** 知识：词面命中权重 */
    public static let LEXICAL_WEIGHT: Float64 = 0.1f64
    /** 知识：词面命中数的计分上限（防止长文档堆词刷分） */
    public static let LEXICAL_CAP: Float64 = 5.0f64

    /** 记忆融合：0.7 * dense + 0.3 * sparse */
    public static func fuseMemory(dense: Float64, sparse: Float64): Float64 {
        MEMORY_DENSE_WEIGHT * dense + MEMORY_SPARSE_WEIGHT * sparse
    }

    /** 记忆重排：0.4 * 标题 + 0.6 * 正文（只改顺序，不改分数） */
    public static func rerank(title: Float64, content: Float64): Float64 {
        RERANK_TITLE_WEIGHT * title + RERANK_CONTENT_WEIGHT * content
    }

    /** 知识融合：dense + 0.1 * min(lexical, 5.0) */
    public static func fuseKnowledge(dense: Float64, lexical: Float64): Float64 {
        let capped = if (lexical > LEXICAL_CAP) {
            LEXICAL_CAP
        } else {
            lexical
        }
        dense + LEXICAL_WEIGHT * capped
    }
}
